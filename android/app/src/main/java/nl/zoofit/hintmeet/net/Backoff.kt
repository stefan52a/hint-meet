package nl.zoofit.hintmeet.net

/** Wachttijd tussen pogingen om te verbinden: 1, 2, 4, 8 s, daarna steeds 10 s. */
class Backoff {
    private var attempt = 0

    fun next(): Long {
        val ms = if (attempt >= 4) 10_000L else 1000L shl attempt
        attempt++
        return ms
    }

    fun reset() {
        attempt = 0
    }
}
