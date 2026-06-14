"""Fixture: a `*_pb2.py` filename — should flip the generated flag.

Mirrors the protobuf codegen convention. Lives at the fixture root (NOT under
generated/) so the test isolates the filename-suffix branch of the rule from
the path-segment branch.
"""


class ProtobufShape:
    proto_field: str
