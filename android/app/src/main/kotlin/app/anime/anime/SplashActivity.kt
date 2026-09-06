package app.anime.anime

// Preserve the installed launcher component without an image, timer, or engine handoff.
// Inherit the normal Flutter activity so channels and lifecycle have a single owner.
class SplashActivity : MainActivity()
