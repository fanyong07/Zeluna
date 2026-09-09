package app.anime.anime

internal object VideoDecodeCompatibility {
    // The observed x86 Android runtime masks its model/manufacturer as a phone,
    // defeating media-kit's emulator detection. Use the primary ABI, not the
    // translated ARM ABIs also advertised by that runtime. Preserve GPU output.
    fun requiresSoftwareDecode(primaryAbi: String?): Boolean =
        primaryAbi == "x86" || primaryAbi == "x86_64"
}
