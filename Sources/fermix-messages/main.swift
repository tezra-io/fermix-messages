import Foundation
import FermixMessagesCore

// Become this process's own TCC responsible process before anything else; a no-op in
// the re-exec'd image.
SelfDisclaim.ensure()
exit(CLI.main(CommandLine.arguments))
