package app.anime.anime

internal object VideoDecodeCompatibility {
    // The observed x86 Android runtime masks its model/manufacturer as a phone,
    // defeating media-kit's emulator detection. Use the primary ABI, not the
    // translated ARM ABIs also advertised by that runtime. Preserve GPU output.
    fun requiresSoftwareDecode(primaryAbi: String?): Boolean =
        primaryAbi == "x86" || primaryAbi == "x86_64"

    // Direct Surface output is deliberately narrower than the old software
    // decoder workaround: require both the affected API/ABI and an explicit
    // emulator build marker. An x86 physical device keeps the original path.
    fun requiresDirectSurface(
        api: Int,
        primaryAbi: String?,
        hardware: String?,
        fingerprint: String?,
        product: String?,
        model: String?,
    ): Boolean {
        if (api < 35 || primaryAbi != "x86_64") return false
        val hw = hardware.orEmpty().lowercase()
        val fp = fingerprint.orEmpty().lowercase()
        val prod = product.orEmpty().lowercase()
        val name = model.orEmpty().lowercase()
        return hw == "ranchu" || hw == "goldfish" ||
            fp.startsWith("generic/") || fp.startsWith("generic_x86_64/") ||
            fp.contains("/emulator") || prod.startsWith("sdk_gphone") ||
            prod.startsWith("sdk_phone") || prod == "sdk" ||
            name.contains("android sdk built for")
    }
}
