################################################################################
#
# python-importlib-metadata
#
# Moonraker imports the BACKPORT explicitly: moonraker/utils/source_info.py does `from importlib_metadata import Distribution, PathDistribution, PackageMetadata`. Python 3.12's stdlib importlib.metadata does NOT satisfy that import, so this is required even on 3.12.
#
# Not packaged by Buildroot 2025.02.18 - that is the ONLY reason this exists.
# Every dependency upstream already provides is used from upstream instead.
#
################################################################################

PYTHON_IMPORTLIB_METADATA_VERSION = 8.4.0
PYTHON_IMPORTLIB_METADATA_SOURCE = importlib_metadata-8.4.0.tar.gz
PYTHON_IMPORTLIB_METADATA_SITE = https://files.pythonhosted.org/packages/c0/bd/fa8ce65b0a7d4b6d143ec23b0f5fd3f7ab80121078c465bc02baeaab22dc
PYTHON_IMPORTLIB_METADATA_SETUP_TYPE = pep517
PYTHON_IMPORTLIB_METADATA_LICENSE = Apache-2.0
PYTHON_IMPORTLIB_METADATA_LICENSE_FILES = LICENSE
PYTHON_IMPORTLIB_METADATA_DEPENDENCIES = host-python-setuptools

$(eval $(python-package))
