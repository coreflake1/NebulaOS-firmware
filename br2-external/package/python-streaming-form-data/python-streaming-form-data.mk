################################################################################
#
# python-streaming-form-data
#
# Moonraker streaming multipart upload parser (moonraker-requirements.txt: streaming-form-data>=1.11.0,<=1.19.1). Ships a NATIVE CPython extension, _parser.
#
# Not packaged by Buildroot 2025.02.18 - that is the ONLY reason this exists.
# Every dependency upstream already provides is used from upstream instead.
#
################################################################################

PYTHON_STREAMING_FORM_DATA_VERSION = 1.19.1
PYTHON_STREAMING_FORM_DATA_SOURCE = streaming_form_data-1.19.1.tar.gz
PYTHON_STREAMING_FORM_DATA_SITE = https://files.pythonhosted.org/packages/f9/fa/a9975245eefac04421a219e8007f9a4ae156b701b94baffb4d15af43304d
PYTHON_STREAMING_FORM_DATA_SETUP_TYPE = setuptools
PYTHON_STREAMING_FORM_DATA_LICENSE = MIT
PYTHON_STREAMING_FORM_DATA_LICENSE_FILES = LICENSE.txt

# BUILD/RUNTIME DEPENDENCIES
#
# pyproject.toml uses setuptools.build_meta and requires only setuptools. The
# sdist ships a pre-generated _parser.c, so Cython is NOT needed at build time -
# only a C compiler, which the cross toolchain provides.
# No dependency beyond what SETUP_TYPE=setuptools adds automatically.

$(eval $(python-package))
