# Linux installation

Build standalone NeLisp, then build and stage both Fcitx 5 and IBus adapters:

```sh
make standalone-reader
cmake -S platform/linux -B platform/linux/build -DCMAKE_INSTALL_PREFIX=/usr
cmake --build platform/linux/build
sudo cmake --install platform/linux/build
```

Restart Fcitx 5 or IBus and add **NeLisp Japanese** in the corresponding
configuration tool. The installation includes the runtime, engine sources,
dictionary, Fcitx addon, and IBus component.
