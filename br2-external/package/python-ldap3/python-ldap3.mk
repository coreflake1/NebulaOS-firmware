################################################################################
#
# python-ldap3
#
# Moonraker LDAP authentication source (moonraker-requirements.txt: ldap3==2.9.1).
#
# Not packaged by Buildroot 2025.02.18 - that is the ONLY reason this exists.
# Every dependency upstream already provides is used from upstream instead.
#
################################################################################

PYTHON_LDAP3_VERSION = 2.9.1
PYTHON_LDAP3_SOURCE = ldap3-2.9.1.tar.gz
PYTHON_LDAP3_SITE = https://files.pythonhosted.org/packages/43/ac/96bd5464e3edbc61595d0d69989f5d9969ae411866427b2500a8e5b812c0
PYTHON_LDAP3_SETUP_TYPE = setuptools
PYTHON_LDAP3_LICENSE = LGPL-3.0
PYTHON_LDAP3_LICENSE_FILES = COPYING.LESSER.txt

# BUILD/RUNTIME DEPENDENCIES
#
# Plain setup.py with no setup_requires.
# No dependency beyond what SETUP_TYPE=setuptools adds automatically.

$(eval $(python-package))
