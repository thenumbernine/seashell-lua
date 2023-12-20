#!/bin/env sh
# TODO have ../dist/run do this
# and maybe TODO have ../dist/run allow from->to mapping so this is easier to implement in distinfo
set -e
name=seashell
distpath=../dist
rm -fr dist
${distpath}/run.lua target=linux dontZip
mv dist/${name}-linux64 dist/${name}
cp -R ${distpath}/bin_Windows dist/${name}/data/bin/Windows
cd dist
zip -r ${name}.zip ${name}/
