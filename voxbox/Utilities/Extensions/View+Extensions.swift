//
//  View+Extensions.swift
//  VoxBox
//
//  Created by Karan Singh on 7/1/26.
//

import SwiftUI

extension View {
    /// Applies a standard corner radius to the view
    func standardCornerRadius() -> some View {
        self.cornerRadius(Constants.UI.cornerRadius)
    }
    
    /// Applies standard padding to the view
    func standardPadding() -> some View {
        self.padding(Constants.UI.padding)
    }
    
    /// Settings popup menus. Hide the system chevron (we draw our own) and
    /// tint with text color so the arrows stay visible in dark mode.
    func settingsMenuStyle() -> some View {
        self
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .tint(Color.textPrimary)
    }

    /// Conditionally applies a modifier
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
    
    /// Applies a modifier conditionally with an else clause
    @ViewBuilder
    func `if`<TrueContent: View, FalseContent: View>(
        _ condition: Bool,
        if ifTransform: (Self) -> TrueContent,
        else elseTransform: (Self) -> FalseContent
    ) -> some View {
        if condition {
            ifTransform(self)
        } else {
            elseTransform(self)
        }
    }
}

