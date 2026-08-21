#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
output_dir="${1:-${project_dir}/dist}"
app_dir="${output_dir}/Gitty.app"

swift build --package-path "${project_dir}" -c release
mkdir -p "${app_dir}/Contents/MacOS"
cp "${project_dir}/App/Info.plist" "${app_dir}/Contents/Info.plist"
cp "${project_dir}/.build/release/Gitty" "${app_dir}/Contents/MacOS/Gitty"
mkdir -p "${app_dir}/Contents/Resources"
cp "${project_dir}/App/Assets/Gitty.icns" "${app_dir}/Contents/Resources/Gitty.icns"
codesign --force --sign - "${app_dir}"

print "Built ${app_dir}"
