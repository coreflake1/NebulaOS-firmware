################################################################################
#
# python-wheel-target
#
# Target-side build of `wheel`. Upstream Buildroot provides host-python-wheel
# only. Source, version and hash are deliberately kept identical to upstream's
# package/python-wheel so both come from exactly the same sdist.
#
################################################################################

PYTHON_WHEEL_TARGET_VERSION = 0.45.1
PYTHON_WHEEL_TARGET_SOURCE = wheel-$(PYTHON_WHEEL_TARGET_VERSION).tar.gz
PYTHON_WHEEL_TARGET_SITE = https://files.pythonhosted.org/packages/8a/98/2d9906746cdc6a6ef809ae6338005b3f21bb568bea3165cfc6a243fdc25c
PYTHON_WHEEL_TARGET_SETUP_TYPE = flit
PYTHON_WHEEL_TARGET_LICENSE = MIT
PYTHON_WHEEL_TARGET_LICENSE_FILES = LICENSE.txt

# BUILD/RUNTIME DEPENDENCIES
#
# flit backend; SETUP_TYPE=flit supplies host-python-flit-core automatically.
# No dependency beyond what SETUP_TYPE=flit adds automatically.

$(eval $(python-package))
