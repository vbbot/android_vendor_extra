#!/bin/bash

# GMS / variant config — disabled for local vanilla builds
export WITH_GMS=true
# export GMS_MAKEFILE=gms.mk
# export TARGET_UNOFFICIAL_BUILD_ID=GMS

# SourceForge upload credentials — not used locally
# SF_USER="aryannn999"
# SF_HOST="frs.sourceforge.net"
# SF_PROJECT_ROOT="/home/frs/project/noprincesshere"

JOBS=14
DEVICE="Q25"


convertsecs() {
    ((h=${1}/3600))
    ((m=(${1}%3600)/60))
    ((s=${1}%60))
    printf "%02d:%02d:%02d\n" $h $m $s
}

# Telegram notifications — disabled
# notify_chat() { ... }
# notify_channel() { ... }
# upload_error_log() { ... }

sync_repo() {
    local local_path="$1"
    local remote="$2"
    local branch="${3:-lineage-23.2}"
    local top="${ANDROID_BUILD_TOP:-$PWD}"

    echo "==> Syncing ${local_path} (${branch})"
    cd "${top}" || return 1

    if [[ -d "${local_path}/.git" ]]; then
        cd "${local_path}"
        git fetch "${remote}" "${branch}"
        git checkout -B "${branch}" FETCH_HEAD
    else
        mkdir -p "$(dirname "${local_path}")"
        git clone -b "${branch}" "${remote}" "${local_path}"
    fi

    cd "${top}"
}

apply_patches() {
    local top="${ANDROID_BUILD_TOP:-$PWD}"
    local patches_path="${top}/vendor/extra/patches"

    cd "${top}" || return 1

    if [[ -d "${patches_path}" ]]; then
        for project_name in $(cd "${patches_path}"; echo */); do
            [[ "${project_name}" == "*/" ]] && continue
            local project_path="$(tr _ / <<<"${project_name}")"
            project_path="${project_path%/}"

            cd "${top}/${project_path}" || { echo "[WARN] Path not found: ${project_path}, skipping."; continue; }

            echo "==> Applying patches for: ${project_path}"
            if ! git am "${patches_path}/${project_name}"*.patch --no-gpg-sign; then
                echo "[ERROR] Failed to apply patches for: ${project_path}. Aborting patch set."
                git am --abort &>/dev/null
            fi

            cd "${top}"
        done
    else
        echo "[INFO] No patches directory found at ${patches_path}, skipping."
    fi
}

sync() {
    local top="${ANDROID_BUILD_TOP:-$PWD}"
    local lineage="https://github.com/LineageOS"
    local pixelos="https://github.com/PixelOS-AOSP"

    cd "${top}" || return 1

    repo sync --force-sync -d -j"${JOBS}" || return 1

    # Q25-specific repos
    sync_repo hardware/mediatek             "${lineage}/android_hardware_mediatek"
    sync_repo device/mediatek/sepolicy_vndr "${lineage}/android_device_mediatek_sepolicy_vndr"
    sync_repo packages/apps/ParanoidSense   "${pixelos}/packages_apps_ParanoidSense" "sixteen"
    sync_repo vendor/xelex/Q25              "${lineage}/android_vendor_xelex_Q25" "lineage-23.2"
    # Not needed for Q25:
    # sync_repo hardware/xiaomi              "${lineage}/android_hardware_xiaomi"
    # sync_repo hardware/motorola            "${lineage}/android_hardware_motorola"
    # sync_repo hardware/oplus               "${lineage}/android_hardware_oplus"
    # sync_repo hardware/sony/timekeep       "${lineage}/android_hardware_sony_timekeep"
    # sync_repo hardware/pixelworks/interfaces "${lineage}/android_hardware_pixelworks_interfaces"
    # sync_repo packages/apps/DolbyAtmos     "${pixelos}/android_packages_apps_DolbyAtmos" "sixteen-qpr2"

    apply_patches

    echo "==> Sync complete."
}

function release() {
    local skip_sync=false
    local skip_picks=false
    local top="${ANDROID_BUILD_TOP:-$PWD}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-sync)  skip_sync=true; shift ;;
            --no-picks) skip_picks=true; shift ;;
            -j*)        JOBS="${1#-j}"; shift ;;
            # Unused flags kept for compatibility:
            # --no-ota)   skip_ota=true; shift ;;
            # --vanilla)  use_vanilla=true; shift ;;
            *)          shift ;;
        esac
    done

    cd "${top}" || return 1

    if [[ "${skip_sync}" == "false" ]]; then
        sync
    fi

    if [[ "${skip_picks}" == "false" ]]; then
        apply_patches
    fi

    # GMS variant setup — disabled
    # export WITH_GMS=true
    # export GMS_MAKEFILE=gms.mk
    # export TARGET_UNOFFICIAL_BUILD_ID=GMS

    local build_start=$(date +%s)

    # notify_chat "Compilation for ${DEVICE} started on ${HOSTNAME}."

    rm -rf "out/target/product/${DEVICE}"
    breakfast "${DEVICE}"

    if [[ $? -ne 0 ]]; then
        echo "[ERROR] breakfast failed for ${DEVICE}."
        # upload_error_log "${DEVICE}" "breakfast failed"
        rm -rf "out/target/product/${DEVICE}"
        return 1
    fi

    m bacon -j"${JOBS}"
    local result=$?
    local build_end=$(date +%s)
    local build_time=$(convertsecs "$((build_end - build_start))")

    if [[ ${result} -ne 0 ]]; then
        echo "[ERROR] Build failed for ${DEVICE}. Time: ${build_time}"
        # upload_error_log "${DEVICE}" "build failed. Time: ${build_time}"
        rm -rf "out/target/product/${DEVICE}"
        return 1
    fi

    echo "[INFO] Build complete for ${DEVICE}. Time: ${build_time}"

    # notify_chat "Build complete for ${DEVICE}. Time: ${build_time}"

    # OTA generation — disabled
    # ...

    # SourceForge upload — disabled
    # rsync -Ph "${out}/${filename}" "${SF_USER}@${SF_HOST}:${remote_dir}/"

    # Release channel notification — disabled
    # notify_channel "${release_msg}"
}
