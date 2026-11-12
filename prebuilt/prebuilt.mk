# AstralOS prebuilt apps
PRODUCT_PACKAGES += \
    AstralAI

# MindTheGapps (prebuilt Google apps, baked into the images)
#
# vendor/gapps comes from MindTheGapps/vendor_gapps (branch vic, Android 15),
# declared in .repo/local_manifests/gapps.xml. Build with WITH_GAPPS=false to
# produce a GApps-free build.
WITH_GAPPS ?= true
ifeq ($(WITH_GAPPS),true)
$(call inherit-product-if-exists, vendor/gapps/arm64/arm64-vendor.mk)
endif

# Pixel-like Material 3 Expressive Settings UI (card preferences, large headers).
# This only switches the layout/theme; all AstralOS colors still come from the
# framework theme overlays.
PRODUCT_PRODUCT_PROPERTIES += \
    is_expressive_design_enabled=true
