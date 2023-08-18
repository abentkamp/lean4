#!/bin/bash


parent_path=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )

CODE=`(cat $parent_path/wasm.js)`

cd $parent_path/build/release/stage1/lib/temp
cat <(echo $CODE) hello.js | node
