struct TouchDeviceArbitrationGate {
    typealias DeviceID = Int
    typealias ContactGeneration = UInt64

    struct Contact: Hashable {
        let deviceID: DeviceID
        let generation: ContactGeneration
    }

    enum Decision: Equatable {
        case accept
        case ignore
        /// The contact may have started after the current owner's physical zero,
        /// but that zero frame has not reached the state machine yet. The caller
        /// must retain the frame until `nextPromotableContact` becomes available.
        case deferClaim
    }

    struct DeferredPromotion: Equatable {
        let contact: Contact
        let startTimestamp: Double
    }

    private(set) var ownerContact: Contact?
    private(set) var ownerStartTimestamp: Double?
    private var blockedContacts: Set<Contact> = []
    private var deferredClaims: [Contact: Double] = [:]
    private var promotableClaims: [Contact: Double] = [:]
    private var latestOwnerEndTimestamp: Double?

    var ownerDeviceID: DeviceID? {
        ownerContact?.deviceID
    }

    mutating func processTouchFrame(
        deviceID: DeviceID,
        contactGeneration: ContactGeneration = 0,
        touchCount: Int,
        allowClaim: Bool = true,
        eventTimestamp: Double? = nil
    ) -> Decision {
        guard touchCount >= 0 else { return .ignore }
        let contact = Contact(
            deviceID: deviceID,
            generation: contactGeneration
        )
        let timestamp = validTimestamp(eventTimestamp)

        if blockedContacts.contains(contact) {
            if touchCount == 0 {
                blockedContacts.remove(contact)
                deferredClaims.removeValue(forKey: contact)
                promotableClaims.removeValue(forKey: contact)
            }
            return .ignore
        }

        if let ownerContact {
            guard ownerContact == contact else {
                if touchCount == 0 {
                    deferredClaims.removeValue(forKey: contact)
                    promotableClaims.removeValue(forKey: contact)
                    return .ignore
                }

                if deferredClaims[contact] != nil {
                    if let timestamp {
                        rememberDeferredClaim(contact, startTimestamp: timestamp)
                    }
                    return .deferClaim
                }

                if promotableClaims[contact] != nil {
                    if let timestamp {
                        rememberPromotableClaim(contact, startTimestamp: timestamp)
                    }
                    return .deferClaim
                }

                guard allowClaim else {
                    blockedContacts.insert(contact)
                    return .ignore
                }

                // If an earlier owner's zero is already known, this frame is
                // not ambiguous anymore: its contact physically overlapped
                // that owner and must stay blocked through its own zero.
                if let timestamp,
                   let latestOwnerEndTimestamp,
                   timestamp < latestOwnerEndTimestamp {
                    blockedContacts.insert(contact)
                    return .ignore
                }

                if let timestamp {
                    rememberDeferredClaim(contact, startTimestamp: timestamp)
                    return .deferClaim
                } else {
                    blockedContacts.insert(contact)
                }
                return .ignore
            }

            if touchCount == 0 {
                self.ownerContact = nil
                resolveOwnerBoundary(at: timestamp)
                ownerStartTimestamp = nil
            }
            return .accept
        }

        guard touchCount > 0 else {
            deferredClaims.removeValue(forKey: contact)
            promotableClaims.removeValue(forKey: contact)
            return .ignore
        }

        if deferredClaims[contact] != nil {
            if let timestamp {
                rememberDeferredClaim(contact, startTimestamp: timestamp)
            }
            return .deferClaim
        }

        if promotableClaims[contact] != nil {
            if let timestamp {
                rememberPromotableClaim(contact, startTimestamp: timestamp)
            }
            return .deferClaim
        }

        guard allowClaim else {
            blockedContacts.insert(contact)
            return .ignore
        }

        // A resolved deferred claim reserves the next ownership transition.
        // Other timestamped starts join the promotable set so physical order,
        // rather than main-queue delivery order, decides which one is promoted.
        if !promotableClaims.isEmpty {
            if let timestamp {
                rememberPromotableClaim(contact, startTimestamp: timestamp)
                return .deferClaim
            }
            blockedContacts.insert(contact)
            return .ignore
        }

        // A positive frame can arrive on main after the owner zero even though
        // its hardware timestamp proves the contacts physically overlapped.
        if let timestamp,
           let latestOwnerEndTimestamp,
           timestamp < latestOwnerEndTimestamp {
            blockedContacts.insert(contact)
            return .ignore
        }

        ownerContact = contact
        ownerStartTimestamp = timestamp
        return .accept
    }

    var nextPromotableContact: DeferredPromotion? {
        promotableClaims
            .map { DeferredPromotion(contact: $0.key, startTimestamp: $0.value) }
            .min(by: promotionPrecedes)
    }

    /// Claims the earliest contact proven to start at or after the previous
    /// owner's zero timestamp. The integration layer must then replay that
    /// contact's retained touch frames beginning with a synthetic 0 -> N finger
    /// transition; calling the normal owner path alone would lose that boundary.
    mutating func promoteNextDeferredContact() -> DeferredPromotion? {
        guard ownerContact == nil,
              let promotion = nextPromotableContact else {
            return nil
        }

        promotableClaims.removeValue(forKey: promotion.contact)

        // Every later candidate may overlap the promoted contact. Put those
        // claims back into the deferred set until this new owner reaches zero.
        let remainingPromotableClaims = Array(promotableClaims)
        for (contact, startTimestamp) in remainingPromotableClaims {
            rememberDeferredClaim(contact, startTimestamp: startTimestamp)
        }
        promotableClaims.removeAll()

        ownerContact = promotion.contact
        ownerStartTimestamp = promotion.startTimestamp
        return promotion
    }

    func processForce(
        deviceID: DeviceID,
        contactGeneration: ContactGeneration = 0
    ) -> Decision {
        ownerContact == Contact(
            deviceID: deviceID,
            generation: contactGeneration
        ) ? .accept : .ignore
    }

    mutating func reset() {
        ownerContact = nil
        ownerStartTimestamp = nil
        blockedContacts.removeAll()
        deferredClaims.removeAll()
        promotableClaims.removeAll()
        latestOwnerEndTimestamp = nil
    }

    private func validTimestamp(_ timestamp: Double?) -> Double? {
        guard let timestamp,
              timestamp.isFinite,
              timestamp > 0 else {
            return nil
        }
        return timestamp
    }

    private mutating func rememberDeferredClaim(
        _ contact: Contact,
        startTimestamp: Double
    ) {
        if let existing = deferredClaims[contact] {
            deferredClaims[contact] = min(existing, startTimestamp)
        } else {
            deferredClaims[contact] = startTimestamp
        }
    }

    private mutating func rememberPromotableClaim(
        _ contact: Contact,
        startTimestamp: Double
    ) {
        if let existing = promotableClaims[contact] {
            promotableClaims[contact] = min(existing, startTimestamp)
        } else {
            promotableClaims[contact] = startTimestamp
        }
    }

    private mutating func resolveOwnerBoundary(at timestamp: Double?) {
        guard let timestamp,
              ownerStartTimestamp.map({ timestamp >= $0 }) ?? true else {
            // Without a comparable hardware boundary, promoting a deferred
            // contact could splice two physical contacts together. Fail closed.
            blockedContacts.formUnion(deferredClaims.keys)
            deferredClaims.removeAll()
            promotableClaims.removeAll()
            return
        }

        if let latestOwnerEndTimestamp {
            self.latestOwnerEndTimestamp = max(latestOwnerEndTimestamp, timestamp)
        } else {
            latestOwnerEndTimestamp = timestamp
        }

        let claimsToResolve = Array(deferredClaims)
        for (contact, startTimestamp) in claimsToResolve {
            if startTimestamp < timestamp {
                blockedContacts.insert(contact)
            } else {
                rememberPromotableClaim(contact, startTimestamp: startTimestamp)
            }
        }
        deferredClaims.removeAll()
    }

    private func promotionPrecedes(
        _ lhs: DeferredPromotion,
        _ rhs: DeferredPromotion
    ) -> Bool {
        if lhs.startTimestamp != rhs.startTimestamp {
            return lhs.startTimestamp < rhs.startTimestamp
        }
        if lhs.contact.deviceID != rhs.contact.deviceID {
            return lhs.contact.deviceID < rhs.contact.deviceID
        }
        return lhs.contact.generation < rhs.contact.generation
    }
}
