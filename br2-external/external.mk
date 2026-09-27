# NebulaOS BR2_EXTERNAL makefile entry point.
#
# Buildroot includes this once; it in turn includes every NebulaOS package
# definition. Nothing here modifies upstream behaviour - it only ADDS
# packages that Buildroot 2025.02.18 does not provide.
include $(sort $(wildcard $(BR2_EXTERNAL_NEBULAOS_PATH)/package/*/*.mk))
