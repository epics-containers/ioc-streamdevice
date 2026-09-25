ARG IMAGE_EXT

ARG REGISTRY=ghcr.io/epics-containers
ARG RUNTIME=${REGISTRY}/epics-base${IMAGE_EXT}-runtime:7.0.10ec2
ARG DEVELOPER=${REGISTRY}/epics-base${IMAGE_EXT}-developer:7.0.10ec2

##### build stage ##############################################################
FROM  ${DEVELOPER} AS developer

# The devcontainer mounts the project root to /epics/generic-source
# Using the same location here makes devcontainer/runtime differences transparent.
ENV SOURCE_FOLDER=/epics/generic-source
# connect ioc source folder to its know location
RUN ln -s ${SOURCE_FOLDER}/ioc ${IOC}

# get the current versions of pvi and ibek
COPY requirements.txt requirements.txt
RUN uv pip install --upgrade -r requirements.txt

WORKDIR ${SOURCE_FOLDER}/ibek-support

COPY ibek-support/_ansible _ansible
ENV PATH=$PATH:${SOURCE_FOLDER}/ibek-support/_ansible

# VisualDCT: build stage only tool that flattens VDCT .vdb files into
# .template files, so modules with vdbs build from pristine upstream sources.
# Nothing is registered for the runtime stage - see ibek-support/vdct/README.md
COPY ibek-support/vdct/ vdct
RUN ansible.sh vdct --tags system,pre_build_tasks

COPY ibek-support/iocStats/ iocStats
RUN ansible.sh iocStats

# sequencer is required by std, which has SNL sources (femto.st, delayDo.st)
# needing snc, and links against seq and pv. No IOC uses the sequencer
# directly, but std cannot be built without it.
COPY ibek-support/sequencer/ sequencer
RUN ansible.sh sequencer

COPY ibek-support/sscan/ sscan
RUN ansible.sh sscan

COPY ibek-support/calc/ calc
RUN ansible.sh calc

COPY ibek-support/asyn/ asyn/
RUN ansible.sh asyn

COPY ibek-support/busy/ busy
RUN ansible.sh busy

COPY ibek-support/autosave/ autosave
RUN ansible.sh autosave

COPY ibek-support/pvlogging/ pvlogging/
RUN ansible.sh pvlogging

# std must follow asyn and sequencer: stdInclude.dbd includes asyn.dbd so
# dbdExpand.pl cannot create std.dbd until asyn is installed, and libstd.a
# needs snc for the .st sources. This matches the module order of the core
# group in ibek-support/build-groups.yml.
COPY ibek-support/std/ std
RUN ansible.sh std

COPY ibek-support/StreamDevice/ StreamDevice
RUN ansible.sh StreamDevice

# get the ioc source and build it
COPY ioc ${SOURCE_FOLDER}/ioc
RUN ansible.sh ioc

# generate a manifest of installed EPICS modules and python packages
# IOC_VERSION is declared here, not earlier: every RUN after an ARG sees it,
# so a new value (each branch or tag) would rebuild all the steps above
ARG IOC_VERSION=unknown
COPY scripts/generate_manifest.py /tmp/generate_manifest.py
RUN python3 /tmp/generate_manifest.py "${IOC_VERSION}"

##### runtime preparation stage ################################################
FROM developer AS runtime_prep

# get the products from the build stage and reduce to runtime assets only
# /python is created by uv and is needed in the runtime target
# /epics/versions.json is the manifest of support module and python versions
RUN ibek ioc extract-runtime-assets /assets /python /epics/versions.json

##### runtime stage ############################################################
FROM ${RUNTIME} AS runtime

# get runtime assets from the preparation stage
COPY --from=runtime_prep /assets /

# install runtime system dependencies, collected from install.sh scripts
RUN ibek support apt-install-runtime-packages

# launch the startup script with stdio-expose to allow console connections
CMD ["bash", "-c", "${IOC}/start.sh"]
