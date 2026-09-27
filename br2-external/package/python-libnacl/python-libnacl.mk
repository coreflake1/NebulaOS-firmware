################################################################################
#
# python-libnacl
#
# Moonraker API-key/JWT crypto (moonraker-requirements.txt: libnacl==2.1.0). A ctypes binding to libsodium, NOT the same as Buildroot's python-pynacl (a CFFI binding with a different module name); Moonraker imports libnacl specifically.
#
# Not packaged by Buildroot 2025.02.18 - that is the ONLY reason this exists.
# Every dependency upstream already provides is used from upstream instead.
#
################################################################################

PYTHON_LIBNACL_VERSION = 2.1.0
PYTHON_LIBNACL_SOURCE = libnacl-2.1.0.tar.gz
PYTHON_LIBNACL_SITE = https://files.pythonhosted.org/packages/df/fc/65daa1a3fd7dd939133c30c6d393ea47e32317d2195619923b67daa29d60
PYTHON_LIBNACL_SETUP_TYPE = pep517
PYTHON_LIBNACL_LICENSE = Apache-2.0
PYTHON_LIBNACL_LICENSE_FILES = LICENSE
PYTHON_LIBNACL_DEPENDENCIES = host-python-poetry-core libsodium

$(eval $(python-package))
