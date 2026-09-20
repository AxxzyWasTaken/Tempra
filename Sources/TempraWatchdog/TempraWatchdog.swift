import Foundation
import TempraSafety

@main
enum TempraWatchdogMain {
    static func main() {
        exit(ProcessGuardianService.run())
    }
}
