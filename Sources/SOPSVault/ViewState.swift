import SwiftUI

// Qualifying the property-wrapper type avoids the same-named State macro in newer SDKs.
// This remains the original SwiftUI wrapper supported by macOS 14.
typealias ViewState<Value> = SwiftUI.State<Value>
