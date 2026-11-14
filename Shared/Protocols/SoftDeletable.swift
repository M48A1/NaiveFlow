//
//  SoftDeletable.swift
//  NaiveFlow
//
//  Created by NodePassProject on 7/18/26.
//

import Foundation

nonisolated protocol SoftDeletable: Sendable {
    var deletedAt: Date? { get }
    var updatedAt: Date { get }
}
