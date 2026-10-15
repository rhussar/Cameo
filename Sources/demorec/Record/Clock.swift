import CoreMedia

/// One host-clock timestamp shared by every writer so the separate files line up at t = 0.
enum SharedClock {
    static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}
