# -------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation.  All rights reserved.
# Licensed under the MIT License.
# --------------------------------------------------------------------------
from logging import getLogger
from typing import Dict

import numpy as np
from fusion_base import Fusion
from onnx import TensorProto, helper
from onnx_model import OnnxModel

logger = getLogger(__name__)


class FusionGroupNorm(Fusion):
    def __init__(self, model: OnnxModel):
        super().__init__(model, "GroupNorm", "Add")

    def fuse(self, add_node, input_name_to_nodes: Dict, output_name_to_node: Dict):
        """
         Fuse Group Normalization subgraph into one node GroupNorm.
         The following is the pattern with swish activation:
               +----------------Shape-------------------------------+
               |                                                    |
               |    (0, 32, -1)                                     v     (512x1x1) (512x1x1)
           [Root] --> Reshape -------> InstanceNormalization --> Reshape ---> Mul --> Add --> Mul--> [output]
        Bx512xHxW                 (scale=ones(32), B=zeros(32))                        |       ^     Bx512xHxW
                                                                                       |       |
                                                                                       +--->Sigmoid
         The following is the pattern without swish activation:
               +----------------Shape-------------------------------+
               |                                                    |
               |    (0, 32, -1)                                     v     (512x1x1) (512x1x1)
           [Root] --> Reshape -------> InstanceNormalization --> Reshape ---> Mul --> Add -->[output]
        Bx512xHxW                 (scale=ones(32), B=zeros(32))                             Bx512xHxW
        """
        nodes = self.model.match_parent_path(
            add_node, ["Mul", "Reshape", "InstanceNormalization", "Reshape"], [0, 0, 0, 0], output_name_to_node
        )
        if nodes is None:
            return

        weight_mul, reshape_4d, instance_norm, reshape_3d = nodes
        root = reshape_3d.input[0]

        parents = self.model.match_parent_path(reshape_4d, ["Shape"], [1], output_name_to_node)
        if parents is None:
            return
        if parents[0].input[0] != root:
            return
        shape_node = parents[0]

        # Check whether it has swish activation.
        swish_mul = self.model.find_first_child_by_type(add_node, "Mul")
        swish_sigmoid = None
        if swish_mul is not None:
            sigmoid_path = self.model.match_parent_path(swish_mul, ["Sigmoid"], [None], output_name_to_node)
            if sigmoid_path is not None:
                swish_sigmoid = sigmoid_path[0]

        weight_input = weight_mul.input[1 - self.model.input_index(reshape_4d.output[0], weight_mul)]
        if not self.model.is_constant_with_specified_dimension(weight_input, 3, "group norm weight"):
            return

        bias_input = add_node.input[1 - self.model.input_index(weight_mul.output[0], add_node)]
        if not self.model.is_constant_with_specified_dimension(bias_input, 3, "layernorm bias"):
            return

        weight = self.model.get_constant_value(weight_input)
        if not (len(weight.shape) == 3 and weight.shape[1] == 1 and weight.shape[2] == 1):
            return

        bias = self.model.get_constant_value(bias_input)
        if not (len(bias.shape) == 3 and bias.shape[1] == 1 and bias.shape[2] == 1):
            return

        weight_elements = np.prod(weight.shape)
        bias_elements = np.prod(bias.shape)
        if weight_elements != bias_elements:
            return

        instance_norm_scale = self.model.get_constant_value(instance_norm.input[1])
        if instance_norm_scale is None:
            return
        instance_norm_bias = self.model.get_constant_value(instance_norm.input[2])
        if instance_norm_bias is None:
            return

        if not (
            len(instance_norm_scale.shape) == 1
            and len(instance_norm_bias.shape) == 1
            and instance_norm_scale.shape == instance_norm_bias.shape
            and instance_norm_scale.shape[0] == 32
        ):
            return

        if not np.allclose(np.ones_like(instance_norm_scale), instance_norm_scale):
            return
        if not np.allclose(np.zeros_like(instance_norm_bias), instance_norm_bias):
            return

        group_norm_name = self.model.create_node_name("GroupNorm", name_prefix="GroupNorm")

        gamma = helper.make_tensor(
            name=group_norm_name + "_gamma",
            data_type=TensorProto.FLOAT,
            dims=[weight_elements],
            vals=weight.flatten().tolist(),
        )
        self.model.add_initializer(gamma, self.this_graph_name)

        beta = helper.make_tensor(
            name=group_norm_name + "_beta",
            data_type=TensorProto.FLOAT,
            dims=[bias_elements],
            vals=bias.flatten().tolist(),
        )
        self.model.add_initializer(beta, self.this_graph_name)

        last_node = add_node
        subgraph_nodes = [add_node, weight_mul, reshape_4d, instance_norm, reshape_3d, shape_node]
        has_swish = swish_mul and swish_sigmoid
        if swish_mul and swish_sigmoid:
            subgraph_nodes.extend([swish_mul, swish_sigmoid])
            last_node = swish_mul

        if not self.model.is_safe_to_fuse_nodes(
            subgraph_nodes,
            last_node.output,
            input_name_to_nodes,
            output_name_to_node,
        ):
            self.node_to_remove.extend([last_node])
        else:
            self.nodes_to_remove.extend(subgraph_nodes)

        # instance_norm_scale might from Constant node. Use prune graph to clear it.
        self.prune_graph = True

        new_node = helper.make_node(
            "GroupNorm",
            inputs=[root, group_norm_name + "_gamma", group_norm_name + "_beta"],
            outputs=[last_node.output[0]],
        )

        new_node.attribute.extend(instance_norm.attribute)
        new_node.attribute.extend([helper.make_attribute("groups", 32)])
        new_node.attribute.extend([helper.make_attribute("swish", 1 if has_swish else 0)])
        new_node.domain = "com.microsoft"
        self.nodes_to_add.append(new_node)
        self.node_name_to_graph_name[new_node.name] = self.this_graph_name