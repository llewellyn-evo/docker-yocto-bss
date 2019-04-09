# Docker/Yocto Build System Setup
#     by komar@evologics.de 2018-2019 Evologics GmbH
# This project helps make build system for embedded platform by using docker and yocto.

MACHINE_CONFIG    = default

# Folders with source and build files
SOURCES_DIR       = sources
BUILD_DIR        ?= build-$(MACHINE)

# If layer branch not set with "branch=" option, YOCTO_RELEASE will be used.
# If layer has no such branch, 'master' branch will be used.
YOCTO_RELEASE     = thud

# Docker settings
DOCKER_IMAGE      = crops/poky
DOCKER_REPO       = debian-9
DOCKER_WORK_DIR   = /work
DOCKER_BIND       = -v $$(pwd):$(DOCKER_WORK_DIR)

# If the file "home/.use_home" exists, bind "home" folder to the container.
ifneq (,$(wildcard home/.use_home))
        DOCKER_BIND += -v $$(pwd)/home/:/home/pokyuser/
endif

# Cmdline to run docker.
DOCKER_RUN        = docker run -it --rm $(DOCKER_BIND)                 \
                    --name="$(MACHINE)"                                \
                    $(DOCKER_IMAGE):$(DOCKER_REPO)                     \
                    --workdir=$(DOCKER_WORK_DIR)/$(BUILD_DIR)

# Include saved config
-include .config.mk

ifeq ($(MACHINE),)
$(error Variable MACHINE must be set: $(notdir $(wildcard machine/*)))
endif

# Include machine config with a possibility to override everything above
include machine/$(MACHINE)/$(MACHINE_CONFIG).mk

comma := ,
# Iterate over lines in LAYERS and fill necessary variables
$(foreach line, $(addprefix url=, $(LAYERS)),                               \
        $(eval line_sep = $(subst ;,  ,$(line)))                            \
        $(eval name := $(lastword $(subst /,  ,$(firstword $(line_sep)))))  \
	$(eval name := $(name:%.git=%))                                     \
        $(foreach property, $(line_sep),                                    \
            $(eval LAYER_$(name)_$(property))                               \
        )                                                                   \
                                                                            \
        $(eval dir := $(addprefix $(SOURCES_DIR)/, $(name)))                \
        $(eval subdirs_sep = $(subst $(comma),  ,$(LAYER_$(name)_subdirs))) \
                                                                            \
        $(eval LAYER_$(name)_branch ?= $(YOCTO_RELEASE))                    \
                                                                            \
        $(if $(value LAYER_$(name)_subdirs),                                \
            $(foreach subdir, $(subdirs_sep),                               \
                $(eval LAYERS_DIR += $(addsuffix /$(subdir), $(dir)))       \
                $(eval LAYER_$(subdir)_url := $(LAYER_$(name)_url))         \
                $(eval LAYER_$(subdir)_branch := $(LAYER_$(name)_branch))   \
            )                                                               \
        ,                                                                   \
            $(eval LAYERS_DIR += $(dir))                                    \
        )                                                                   \
 )

.PHONY: distclean help

help:
	@echo 'List targets:'
	@echo ' list-machine    - Show available machines'
	@echo ' list-config     - Show available configs for a given machine'
	@echo 'Cleaning targets:'
	@echo ' distclean	- Remove all generated files and directories'
	@echo ' clean-bbconfigs - Remove bblayers.conf and local.conf files'
	@echo ' clean-images    - Remove resulting target images and packages'
	@echo ''
	@echo 'Add/remove layers:'
	@echo ' add-layer       - Add one or multiple layers'
	@echo ' remove-layer    - Remove one or multiple layers'
	@echo '  necessary parameter: LAYERS="<layer1> <layer2>"'
	@echo ''
	@echo 'Other generic targets:'
	@echo ' all		- Download docker image, yocto and meta layers and build image $(IMAGE_NAME) for machine $(MACHINE)'
	@echo ' devshell	- Invoke devepoper shell'
	@echo ''
	@echo 'Also docker can be run directly:'
	@echo '$(DOCKER_RUN)'
	@echo ''
	@echo 'And then build:'
	@echo 'bitbake core-image-minimal meta-toolchain'
	@echo ''
	@echo 'TIPS:'
	@echo 'Build binaries and images for RoadRunner on BertaD2 baseboard in separate build directory'
	@echo '$$ make MACHINE=sama5d2-roadrunner-bertad2-qspi BUILD_DIR=build-bertad2-qspi IMAGE_NAME=acme-minimal-image all'
	@echo 'Result binaries and images you can find at $(BUILD_DIR)/tmp/deploy/'

list-machine:
	@ls -1 machine/ | grep -v common | sed '/$(MACHINE)[-.]/! s/\b$(MACHINE)\b/ * &/g'

list-config:
	@echo " * $(MACHINE):"
	@ls -1 machine/$(MACHINE)/ | grep .mk | sed 's/.mk\b//g' | sed '/$(MACHINE_CONFIG)[-.]/! s/\b$(MACHINE_CONFIG)\b/ * &/g'

all: build-poky-container sources layers $(BUILD_DIR) configure
	$(DOCKER_RUN) --cmd "bitbake $(IMAGE_NAME) $(MACHINE_BITBAKE_TARGETS)"
	@echo 'Result binaries and images you can find at $(BUILD_DIR)/tmp/deploy/'

devshell: build-poky-container sources layers $(BUILD_DIR) configure
	$(DOCKER_RUN)

build-poky-container: poky-container/build-and-test.sh

poky-container/build-and-test.sh:
	git clone -b rocko https://github.com/evologics/poky-container
	cd poky-container && \
		BASE_DISTRO=$(DOCKER_REPO) REPO=$(DOCKER_IMAGE) ./build-and-test.sh

sources: $(SOURCES_DIR)

$(SOURCES_DIR):
	git clone -b $(YOCTO_RELEASE) git://git.yoctoproject.org/poky.git $(SOURCES_DIR)

layers: $(LAYERS_DIR)

$(LAYERS_DIR):
	cd $(SOURCES_DIR) && \
		(git clone -b $(LAYER_$(@F)_branch) $(LAYER_$(@F)_url) || git clone $(LAYER_$(@F)_url))

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

configure: $(BUILD_DIR)/conf/local.conf

$(BUILD_DIR)/conf/local.conf:
	$(DOCKER_RUN) --cmd "cd $(DOCKER_WORK_DIR)/$(SOURCES_DIR) && source oe-init-build-env $(DOCKER_WORK_DIR)/$(BUILD_DIR)" 
	for LAYER in $(LAYERS_DIR); do \
		$(DOCKER_RUN) --cmd "bitbake-layers add-layer $(DOCKER_WORK_DIR)/$$LAYER"; \
	done
	for OPT in $(LOCAL_CONF_OPT); do \
		echo $$OPT;					 \
	done >> $(BUILD_DIR)/conf/local.conf

	echo "MACHINE = $(MACHINE)" > .config.mk
	echo "MACHINE_CONFIG = $(MACHINE_CONFIG)" >> .config.mk

add-layer: configure layers
	for LAYER in $(LAYERS_DIR); do \
	$(DOCKER_RUN) --cmd "bitbake-layers add-layer $(DOCKER_WORK_DIR)/$$LAYER"; \
	done

remove-layer: configure
	@echo "REMOVING: $(LAYERS_DIR)"
	@echo -n "Press Ctrl-C to cancel"
	@for i in $$(seq 1 5); do echo -n "." && sleep 1; done
	@echo
	for LAYER in $(LAYERS_DIR); do \
	$(DOCKER_RUN) --cmd "bitbake-layers remove-layer $(DOCKER_WORK_DIR)/$$LAYER && rm -rf $(DOCKER_WORK_DIR)/$$LAYER"; \
	done

clean-bbconfigs:
	rm $(BUILD_DIR)/conf/local.conf $(BUILD_DIR)/conf/bblayers.conf

clean-images:
	rm -rf $(BUILD_DIR)/tmp/deploy

cleanall:
	rm -rf $(BUILD_DIR)/tmp $(BUILD_DIR)/sstate-cache

distclean:
	rm -rf $(BUILD_DIR) $(SOURCES_DIR) poky-container .config.mk

package-index:
	$(DOCKER_RUN) --cmd "bitbake package-index"

ipk-server: package-index
	$(eval IP := $(firstword $(shell ip a | grep dynamic | grep -Po 'inet \K[\d.]+')))
	$(eval PORT := 8080)
	@echo 'Assuming address $(IP):$(PORT)'
	@echo ''
	@echo 'Add following lines to /etc/opkg/opkg.conf'
	@echo ''
	$(eval ipk-archs := $(wildcard $(BUILD_DIR)/tmp/deploy/ipk/*))
	@$(foreach arch, $(ipk-archs), \
	 $(eval arch_strip := $(lastword $(subst /,  ,$(arch))))                 \
	 echo 'src/gz $(arch_strip) http://$(IP):$(PORT)/$(arch_strip)'; \
	 )
	@echo ''
	@cd $(BUILD_DIR)/tmp/deploy/ipk/ && python -m SimpleHTTPServer $(PORT)
