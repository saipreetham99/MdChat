import SwiftUI

/// `@State` by another name. Newer SDKs also declare a `State()` macro that
/// wins the attribute lookup, and the Command Line Tools don't ship the plugin
/// that expands it, so plain `@State` fails to build without Xcode. The alias
/// resolves straight to the property wrapper.
typealias ViewState<Value> = SwiftUI.State<Value>
