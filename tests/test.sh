#!/usr/bin/env sh

size=$(identify -ping -format '%wx%h' $1)
zig build run -- $1 | \
    magick -size $size -depth 8 RGB:- png:- | \
    chafa
