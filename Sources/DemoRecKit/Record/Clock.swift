import CoreMedia

/// One host-clock timestamp shared by every writer so the separate files line up at t = 0.
public enum SharedClock {
    public static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}
