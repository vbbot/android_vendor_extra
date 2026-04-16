#!/bin/bash

export WITH_GMS=true

SF_USER="vbbot"
SF_HOST="frs.sourceforge.net"
SF_PROJECT="Q25-lineage"
SF_PROJECT_ROOT="/home/frs/project/${SF_PROJECT}"

JOBS=14
DEVICE="Q25"
OTA_FILE="ota/${DEVICE}.json"

convertsecs() {
    ((h=${1}/3600))
    ((m=(${1}%3600)/60))
    ((s=${1}%60))
    printf "%02d:%02d:%02d\n" $h $m $s
}

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

    sync_repo hardware/mediatek             "${lineage}/android_hardware_mediatek"
    sync_repo device/mediatek/sepolicy_vndr "${lineage}/android_device_mediatek_sepolicy_vndr"
    sync_repo packages/apps/ParanoidSense   "${pixelos}/packages_apps_ParanoidSense" "sixteen"
    sync_repo vendor/xelex/Q25              "https://github.com/TheMuppets/proprietary_vendor_xelex_Q25" "lineage-23.2"

    apply_patches

    echo "==> Sync complete."
}

# Generates ota/Q25.json from the build output zip and commits it.
generate_ota_json() {
    local zip_path="$1"
    local top="${ANDROID_BUILD_TOP:-$PWD}"
    local filename
    filename="$(basename "${zip_path}")"
    local size
    size="$(stat -c%s "${zip_path}")"
    local sha256
    sha256="$(sha256sum "${zip_path}" | cut -d' ' -f1)"
    local datetime
    datetime="$(stat -c%Y "${zip_path}")"
    local url="https://sourceforge.net/projects/${SF_PROJECT}/files/${DEVICE}/${filename}/download"

    local ota_path="${top}/vendor/extra/${OTA_FILE}"

    cat > "${ota_path}" <<OTAEOF
{
  "response": [
    {
      "datetime": ${datetime},
      "filename": "${filename}",
      "id": "${sha256}",
      "romtype": "UNOFFICIAL",
      "size": ${size},
      "url": "${url}",
      "version": "23.2"
    }
  ]
}
OTAEOF

    echo "==> OTA JSON written: ${ota_path}"
}

# Rsyncs the zip to SourceForge file releases.
upload_to_sf() {
    local zip_path="$1"
    local filename
    filename="$(basename "${zip_path}")"

    echo "==> Uploading ${filename} to SourceForge..."
    rsync -e "ssh -o StrictHostKeyChecking=accept-new" \
          -avP --progress \
          "${zip_path}" \
          "${SF_USER}@${SF_HOST}:${SF_PROJECT_ROOT}/${DEVICE}/"
}

# Commits the updated OTA JSON and pushes to GitHub.
update_ota_github() {
    local top="${ANDROID_BUILD_TOP:-$PWD}"

    echo "==> Pushing OTA JSON to GitHub..."
    cd "${top}/vendor/extra"
    git add "${OTA_FILE}"
    git commit -m "ota: Q25 $(date +%Y%m%d)"
    git push github lineage-23.2
    cd "${top}"
}

function release() {
    local skip_sync=false
    local skip_picks=false
    local skip_upload=false
    local top="${ANDROID_BUILD_TOP:-$PWD}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-sync)    skip_sync=true;   shift ;;
            --no-picks)   skip_picks=true;  shift ;;
            --no-upload)  skip_upload=true; shift ;;
            -j*)          JOBS="${1#-j}";   shift ;;
            *)            shift ;;
        esac
    done

    cd "${top}" || return 1

    if [[ "${skip_sync}" == "false" ]]; then
        sync
    fi

    if [[ "${skip_picks}" == "false" ]]; then
        apply_patches
    fi

    local build_start
    build_start=$(date +%s)

    rm -rf "out/target/product/${DEVICE}"
    breakfast "${DEVICE}"

    if [[ $? -ne 0 ]]; then
        echo "[ERROR] breakfast failed for ${DEVICE}."
        return 1
    fi

    m bacon -j"${JOBS}"
    local result=$?
    local build_end
    build_end=$(date +%s)
    local build_time
    build_time=$(convertsecs "$((build_end - build_start))")

    if [[ ${result} -ne 0 ]]; then
        echo "[ERROR] Build failed for ${DEVICE}. Time: ${build_time}"
        return 1
    fi

    echo "[INFO] Build complete for ${DEVICE}. Time: ${build_time}"

    if [[ "${skip_upload}" == "false" ]]; then
        local zip_path
        zip_path="$(ls "${top}/out/target/product/${DEVICE}/lineage-"*.zip 2>/dev/null | grep -v ota | sort | tail -1)"

        if [[ -z "${zip_path}" ]]; then
            echo "[ERROR] Could not find build zip — skipping upload."
            return 1
        fi

        generate_ota_json "${zip_path}"
        upload_to_sf "${zip_path}"
        update_ota_github
    fi
}
