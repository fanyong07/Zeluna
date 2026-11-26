package app.anime.anime.csp

class CspBridgeException(
    val code: String,
    override val message: String,
    cause: Throwable? = null,
) : Exception(message, cause)
