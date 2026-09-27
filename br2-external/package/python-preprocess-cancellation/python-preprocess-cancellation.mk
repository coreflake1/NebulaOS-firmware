################################################################################
#
# python-preprocess-cancellation
#
# Moonraker gcode object-cancellation preprocessor (moonraker-requirements.txt: preprocess-cancellation==0.2.1).
#
# Not packaged by Buildroot 2025.02.18 - that is the ONLY reason this exists.
# Every dependency upstream already provides is used from upstream instead.
#
################################################################################

PYTHON_PREPROCESS_CANCELLATION_VERSION = 0.2.1
PYTHON_PREPROCESS_CANCELLATION_SOURCE = preprocess_cancellation-0.2.1.tar.gz
PYTHON_PREPROCESS_CANCELLATION_SITE = https://files.pythonhosted.org/packages/4a/56/7e18b0336c1e6c6622411dd0d3a7634b171e4d156a13b1ceaa048682454a
PYTHON_PREPROCESS_CANCELLATION_SETUP_TYPE = pep517
PYTHON_PREPROCESS_CANCELLATION_LICENSE = GPL-3.0
PYTHON_PREPROCESS_CANCELLATION_LICENSE_FILES = LICENSE
PYTHON_PREPROCESS_CANCELLATION_DEPENDENCIES = host-python-poetry-core

$(eval $(python-package))
