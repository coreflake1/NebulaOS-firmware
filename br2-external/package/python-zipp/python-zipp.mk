################################################################################
#
# python-zipp
#
# Runtime dependency of python-importlib-metadata. Present in the current qualified image (zipp-3.20.2.dist-info); 06-verify.sh asserts its presence.
#
# Not packaged by Buildroot 2025.02.18 - that is the ONLY reason this exists.
# Every dependency upstream already provides is used from upstream instead.
#
################################################################################

PYTHON_ZIPP_VERSION = 3.20.2
PYTHON_ZIPP_SOURCE = zipp-3.20.2.tar.gz
PYTHON_ZIPP_SITE = https://files.pythonhosted.org/packages/54/bf/5c0000c44ebc80123ecbdddba1f5dcd94a5ada602a9c225d84b5aaa55e86
PYTHON_ZIPP_SETUP_TYPE = setuptools
PYTHON_ZIPP_LICENSE = MIT
PYTHON_ZIPP_LICENSE_FILES = LICENSE

# BUILD/RUNTIME DEPENDENCIES
#
# pyproject.toml requires setuptools>=61.2 and setuptools_scm[toml]>=3.4.1.
PYTHON_ZIPP_DEPENDENCIES = host-python-setuptools-scm

$(eval $(python-package))
