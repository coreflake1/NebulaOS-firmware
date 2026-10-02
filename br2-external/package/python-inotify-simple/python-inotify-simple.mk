################################################################################
#
# python-inotify-simple
#
# Moonraker filesystem watching (moonraker-requirements.txt: inotify-simple==2.0.1). Distinct from Buildroot's python-pyinotify, which is a different library with a different API.
#
# Not packaged by Buildroot 2025.02.18 - that is the ONLY reason this exists.
# Every dependency upstream already provides is used from upstream instead.
#
################################################################################

PYTHON_INOTIFY_SIMPLE_VERSION = 2.0.1
PYTHON_INOTIFY_SIMPLE_SOURCE = inotify_simple-2.0.1.tar.gz
PYTHON_INOTIFY_SIMPLE_SITE = https://files.pythonhosted.org/packages/e3/5c/bfe40e15d684bc30b0073aa97c39be410a5fbef3d33cad6f0bf2012571e0
PYTHON_INOTIFY_SIMPLE_SETUP_TYPE = setuptools
PYTHON_INOTIFY_SIMPLE_LICENSE = BSD-2-Clause
PYTHON_INOTIFY_SIMPLE_LICENSE_FILES = LICENSE

# BUILD/RUNTIME DEPENDENCIES
#
# pyproject.toml uses setuptools.build_meta and requires only setuptools, which
# SETUP_TYPE=setuptools supplies automatically.
# No dependency beyond what SETUP_TYPE=setuptools adds automatically.

$(eval $(python-package))
