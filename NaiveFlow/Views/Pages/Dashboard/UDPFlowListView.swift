//
//  UDPFlowListView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 9/23/26.
//

import SwiftUI

struct UDPFlowListView: View {
    var body: some View {
        ActivityListView(
            .udp,
            emptyTitle: "No UDP Flows",
            emptySystemImage: "arrow.left.and.right"
        )
        .navigationTitle("UDP Flows")
    }
}
