################################################################################
#
# python-smart-open
#
# Runtime dependency of python-streaming-form-data 1.19.1, which declares
# smart-open>=7.0.5 and does `import smart_open` at module load. Missing from
# the first Buildroot 2025.02.18 image: Moonraker died at import on the printer.
#
# Not packaged by Buildroot 2025.02.18 - that is the ONLY reason this exists.
# Every dependency upstream already provides is used from upstream instead.
#
################################################################################

PYTHON_SMART_OPEN_VERSION = 7.5.0
PYTHON_SMART_OPEN_SOURCE = smart_open-7.5.0.tar.gz
PYTHON_SMART_OPEN_SITE = https://files.pythonhosted.org/packages/67/9a/0a7acb748b86e2922982366d780ca4b16c33f7246fa5860d26005c97e4f3
PYTHON_SMART_OPEN_SETUP_TYPE = setuptools
PYTHON_SMART_OPEN_LICENSE = MIT
PYTHON_SMART_OPEN_LICENSE_FILES = LICENSE

# BUILD/RUNTIME DEPENDENCIES
#
# pyproject.toml requires setuptools>=64 and setuptools_scm>=8 (Buildroot
# 2025.02.18 ships 8.1.0). Its one hard runtime dependency, wrapt, is
# Buildroot's own python-wrapt, selected in Config.in. Everything else it
# can use (boto3, requests, paramiko, ...) is an optional extra, and
# streaming-form-data needs none of them.
PYTHON_SMART_OPEN_DEPENDENCIES = host-python-setuptools-scm

$(eval $(python-package))
