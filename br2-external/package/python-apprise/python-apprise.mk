################################################################################
#
# python-apprise
#
# Moonraker notification backend (scripts/moonraker-requirements.txt: apprise>=1.9.3,<=1.9.8).
#
# Not packaged by Buildroot 2025.02.18 - that is the ONLY reason this exists.
# Every dependency upstream already provides is used from upstream instead.
#
################################################################################

PYTHON_APPRISE_VERSION = 1.9.3
PYTHON_APPRISE_SOURCE = apprise-1.9.3.tar.gz
PYTHON_APPRISE_SITE = https://files.pythonhosted.org/packages/f8/1e/fe19c88c3e1ff96f4ea757bae9f6350060ac28be523507053347aa5d67db
PYTHON_APPRISE_SETUP_TYPE = setuptools
PYTHON_APPRISE_LICENSE = BSD-2-Clause
PYTHON_APPRISE_LICENSE_FILES = LICENSE

$(eval $(python-package))
