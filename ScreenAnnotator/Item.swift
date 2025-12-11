//
//  Item.swift
//  ScreenAnnotator
//
//  Created by Prasanna Kumar Tumula on 12/10/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
