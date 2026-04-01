import Darwin

func processIsRunning(_ pid: Int32) -> Bool {
    guard pid > 0 else {
        return false
    }

    if kill(pid, 0) == 0 {
        return true
    }

    return errno == EPERM
}
