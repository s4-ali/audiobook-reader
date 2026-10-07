# sherpa-onnx (Narrate): its native library looks up these classes, fields and constructors by
# name over JNI, so R8 must not rename or strip them.
-keep class com.k2fsa.sherpa.onnx.** { *; }
# ...and it calls back into our synthesis callback by exact method signature.
-keep class com.audiobook.audiobook_player.narrate.** { *; }
# commons-compress references optional codecs (zstd, xz, brotli, asm) we don't ship or use.
-dontwarn org.apache.commons.compress.**
-dontwarn org.tukaani.xz.**
-dontwarn com.github.luben.zstd.**
-dontwarn org.brotli.dec.**
-dontwarn org.objectweb.asm.**
