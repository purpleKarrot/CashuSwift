import Foundation
import secp256k1
import OSLog

fileprivate let logger = Logger.init(subsystem: "CashuSwift", category: "wallet")

extension Mint {
    
    // MARK: - GET QUOTE
    
    public func getQuote(quoteRequest:QuoteRequest) async throws -> Quote {
        var url = self.url
        
        guard self.keysets.contains(where: { $0.unit == quoteRequest.unit }) else {
            fatalError("the mint does not have a keyset that supports this unit")
        }
        
        switch quoteRequest {
        case let quoteRequest as Bolt11.RequestMintQuote:
            url.append(path: "/v1/mint/quote/bolt11")
            var result = try await Network.post(url: url,
                                                body: quoteRequest,
                                                expected: Bolt11.MintQuote.self)
            result.requestDetail = quoteRequest
            return result
        case let quoteRequest as Bolt11.RequestMeltQuote:
            url.append(path: "/v1/melt/quote/bolt11")
            return try await Network.post(url: url,
                                          body:quoteRequest,
                                          expected: Bolt11.MeltQuote.self)
        default:
            fatalError("User tried to call getQuote using unsupported QuoteRequest type.")
        }
    }
    
    // MARK: - ISSUE
    
    /// # Headline
    /// After paying the quote amount to the mint, use this function to issue the actual ecash as a list of [`String`]s
    /// Leaving `seed` empty will give you proofs from non-deterministic outputs which cannot be recreated from a seed phrase backup
    public func issue(for quote:Quote,
                      seed:String? = nil,
                      preferredDistribution:[Int]? = nil,
                      duplicateHandling:Cashu.DuplicateOutputHandling = .fail) async throws -> [Proof] {
        
        guard let quote = quote as? Bolt11.MintQuote else {
            fatalError("Quote to issue proofs for was not a Bolt11.MintQuote")
        }
        
        guard let requestDetail = quote.requestDetail else {
            fatalError("You need to set requestDetail associated with the quote.")
        }
        
        var distribution:[Int]
        
        if let preferredDistribution = preferredDistribution {
            guard preferredDistribution.reduce(0, +) == requestDetail.amount else {
                fatalError("Specified preferred distribution does not add up to the same amount as the quote.")
            }
            distribution = preferredDistribution
        } else {
            distribution = Cashu.splitIntoBase2Numbers(requestDetail.amount)
        }
        
        guard let keyset = self.keysets.first(where: { $0.active == true &&
                                                       $0.unit == requestDetail.unit }) else {
            fatalError("Could not determine an ACTIVE keyset for this unit \(requestDetail.unit.uppercased())")
        }
        
        // tuple for outputs, blindingfactors, secrets
        // swift does not allow uninitialized tuple declaration
        var outputs = (outputs:[Output](), blindingFactors:[""], secrets:[""])
        if let seed = seed {
            outputs = try Crypto.generateOutputs(amounts: distribution,
                                                 keysetID: keyset.id,
                                                 deterministicFactors: (seed: seed,
                                                                        counter: keyset.derivationCounter))
            keyset.derivationCounter += outputs.outputs.count
        } else {
            outputs = try Crypto.generateOutputs(amounts: distribution,
                                                 keysetID: keyset.id)
        }
        
        let mintRequest = Bolt11.MintRequest(quote: quote.quote, outputs: outputs.outputs)
        
        // TODO: PARSE COMMON ERRORS
        // TODO: CHECK FOR DUPLICATE OUTPUT ERROR, RETRY ACC TO `skipDuplicateOutputs`
        let promises = try await Network.post(url: self.url.appending(path: "/v1/mint/bolt11"),
                                              body: mintRequest,
                                              expected: Bolt11.MintResponse.self)
                    
        let proofs = try Crypto.unblindPromises(promises.signatures,
                                                blindingFactors: outputs.blindingFactors,
                                                secrets: outputs.secrets,
                                                keyset: keyset)
        
        return proofs
    }
    
    // MARK: - SEND
    
    public func send(proofs:[Proof],
                     amount:Int? = nil,
                     seed:String? = nil,
                     memo:String? = nil,
                     duplicateOutputHandling:Cashu.DuplicateOutputHandling = .fail) async throws -> (token:Token,
                                                                                                     change:[Proof]) {
        
        let amount = amount ?? proofs.sum
        
        guard amount <= proofs.sum else {
            fatalError("amount must not be larger than input proofs")
        }
        
        let sendProofs:[Proof]
        let changeProofs:[Proof]
        
        if let selection = proofs.select(amount: amount) {
            sendProofs = selection.selected
            changeProofs = selection.rest
        } else {
            let swapped = try await swap(proofs: proofs, amount: amount)
            sendProofs = swapped.new
            changeProofs = swapped.change
        }
        
        let units = try units(for: sendProofs)
        guard units.count == 1 else {
            fatalError("units needs to contain exactly ONE entry, more means multi unit, less means none found - no bueno")
        }
        
        let proofContainer = ProofContainer(mint: self.url.absoluteString, proofs: sendProofs)
        let token = Token(token: [proofContainer], memo: memo, unit: units.first)
        
        return (token, changeProofs)
    }
    
    // MARK: - RECEIVE
    
    public func receive(token:Token,
                        seed:String? = nil,
                        duplicateOutputHandling:Cashu.DuplicateOutputHandling = .fail) async throws -> [Proof] {
        // TODO: NEEDS TO BE ABLE TO HANDLE P2PK LOCKED ECASH
        // this should check whether proofs are from this mint and not multi unit FIXME: potentially wonky and not very descriptive
        guard let inputProofs = token.token.first?.proofs,
                try self.units(for: inputProofs).count == 1 else {
            fatalError("Proofs to swap are either of mixed unit or foreign to this mint.")
        }
        return try await self.swap(proofs: inputProofs).new
    }
    
    // MARK: - MELT
    // should block until the the payment is made OR timeout reached
    public func melt(quote:Quote,
                     proofs:[Proof]) async throws -> (paid:Bool, change:[Proof]) {
        guard let quote = quote as? Bolt11.MeltQuote else {
            fatalError("you need to pass a Bolt11 melt quote to this function, nothing else is supported yet.")
        }
        
        let meltRequest = Bolt11.MeltRequest(quote: quote.quote, inputs: proofs)
        
        guard proofs.sum > quote.amount + quote.feeReserve else {
            fatalError("inputs do not cover the melt quote amount and fee reserve.")
        }
        
        // TODO: HANDLE TIMEOUT MORE EXPLICITLY
        
        let meltResponse = try await Network.post(url: self.url.appending(path: "/v1/melt/bolt11"), body: meltRequest, expected: Bolt11.MeltQuote.self)
        
        // TODO: PERFORM ACTUAL CHANGE CALCULATION AND RETURN CORRECT PROOFS
        
        // TODO: refactor and improve function design
        
        if let paid = meltResponse.paid {
            return (paid, [])
        } else if let state = meltResponse.state {
            switch state {
            case .paid:
                return (true, [])
            case .unpaid:
                return (false, [])
            case .pending:
                return (false, [])
            }
        } else {
            fatalError("could not find quote state information in response.")
        }
    }
    
    // MARK: - SWAP
    public func swap(proofs:[Proof],
                     amount:Int? = nil,
                     seed:String? = nil,
                     preferredReturnDistribution:[Int]? = nil) async throws -> (new:[Proof],
                                                                         change:[Proof]) {
        let fee = try calculateFee(for: proofs)
        let proofSum = proofs.reduce(0) { $0 + $1.amount }
        let amount = amount ?? (proofSum-fee)
        
        let amountAfterFee = amount - fee
        
//        print("fee: \(fee), \nproofSum:\(proofSum), \namounr:\(amount), \namountAfterFee:\(amountAfterFee)")
        
        guard proofSum >= amountAfterFee else {
            fatalError("target swap amount is larger than sum of proof amounts")
        }
        
        // the number of units from potentially mutliple keysets across input proofs must be 1:
        // less than 1 would mean no matching keyset/unit
        // more than one would imply multiple unit input proofs, which is not supported
        
        let units = try units(for: proofs)
        
        guard units.count == 1 else {
            fatalError("mixed unit inputs or other problem with composition of inputs")
        }
        
        guard let activeKeyset = activeKeysetForUnit(units.first!) else {
            fatalError("no active keyset could be found for unit \(String(describing: units.first))")
        }
        
        // TODO: implement true output selection
        
        let swapDistribution = Cashu.splitIntoBase2Numbers(amountAfterFee)
        let changeDistribution:[Int]
        
        if preferredReturnDistribution == nil {
            changeDistribution = Cashu.splitIntoBase2Numbers(proofSum - amount)
        } else {
            guard preferredReturnDistribution!.reduce(0, +) == (proofSum - amount) else {
                fatalError("preferredReturnDistribution does not add up to expected change amount")
            }
            changeDistribution = preferredReturnDistribution!
        }
        
        let combinedDistribution = (swapDistribution + changeDistribution).sorted()
        
        let deterministicFactors:(String, Int)?
        if let seed {
            deterministicFactors = (seed, activeKeyset.derivationCounter)
            activeKeyset.derivationCounter += combinedDistribution.count
        } else {
            deterministicFactors = nil
        }
        
        let (outputs, bfs, secrets) = try Crypto.generateOutputs(amounts: combinedDistribution,
                                                                 keysetID: activeKeyset.id,
                                                                 deterministicFactors: deterministicFactors)
        
        let swapRequest = SwapRequest(inputs: proofs, outputs: outputs)
        let swapResponse = try await Network.post(url: self.url.appending(path: "/v1/swap"),
                                                  body: swapRequest,
                                                  expected: SwapResponse.self)
        
        var newProofs = try Crypto.unblindPromises(swapResponse.signatures,
                                                   blindingFactors: bfs,
                                                   secrets: secrets,
                                                   keyset: activeKeyset)
        var sendProofs = [Proof]()
        for n in swapDistribution {
            if let index = newProofs.firstIndex(where: {$0.amount == n}) {
                sendProofs.append(newProofs[index])
                newProofs.remove(at: index)
            }
        }
        
        return (sendProofs, newProofs)
    }
    
    // MARK: - RESTORE
    // TODO: should increase batch size, default 10 is way to small
    public func restore(with seed:String,
                        batchSize:Int = 10) async throws -> [Proof] {
        // no need to check validity of seed as function would otherwise crash during first det sec generation
        var restoredProofs = [Proof]()
        for keyset in self.keysets {
            logger.info("Attempting restore for keyset: \(keyset.id) of mint: \(self.url.absoluteString)")
            let (proofs, _, lastMatchCounter) = try await restoreForKeyset(keyset, with: seed, batchSize: batchSize)
            print("last match counter: \(String(describing: lastMatchCounter))")
            
            // FIXME: ugly
            keyset.derivationCounter = lastMatchCounter + 1
            
            let states = try await check(proofs)// ignores pending but should not
            guard states.count == proofs.count else {
                fatalError("could not filter: proofs, spendable need matching count")
            }
            var spendableProofs = [Proof]()
            for i in 0..<states.count {
                if states[i] == .unspent { spendableProofs.append(proofs[i]) }
            }
            
            restoredProofs.append(contentsOf: spendableProofs)
            logger.info("Found \(spendableProofs.count) spendable proofs for keyset \(keyset.id)")
        }
        return restoredProofs
    }
    
    func restoreForKeyset(_ keyset:Keyset, 
                          with seed:String,
                          batchSize:Int) async throws -> (proofs:[Proof],
                                                          totalRestored:Int,
                                                          lastMatchCounter:Int) {
        var proofs = [Proof]()
        var emtpyResponses = 0
        var currentCounter = 0
        var batchLastMatchIndex = 0
        let emptyRuns = 2
        while emtpyResponses < emptyRuns {
            let (outputs,
                 blindingFactors,
                 secrets) = try Crypto.generateOutputs(amounts: Array(repeating: 1, count: batchSize),
                                                       keysetID: keyset.id,
                                                       deterministicFactors: (seed: seed,
                                                                              counter: currentCounter))
            
            
            let request = RestoreRequest(outputs: outputs)
            let response = try await Network.post(url: self.url.appending(path: "/v1/restore"),
                                                  body: request,
                                                  expected: RestoreResponse.self)
            
            currentCounter += batchSize
            
            if response.signatures.isEmpty {
                emtpyResponses += 1
                continue
            } else {
                //reset counter to ensure they are CONSECUTIVE empty responses
                emtpyResponses = 0
                batchLastMatchIndex = outputs.lastIndex(where: { oldOutput in
                    response.outputs.contains(where: {newOut in oldOutput.B_ == newOut.B_})
                }) ?? 0
            }
            var rs = [String]()
            var xs = [String]()
            for i in 0..<outputs.count {
                if response.outputs.contains(where: {$0.B_ == outputs[i].B_}) {
                    rs.append(blindingFactors[i])
                    xs.append(secrets[i])
                }
            }
            
            let batchProofs = try Crypto.unblindPromises(response.signatures,
                                                        blindingFactors: blindingFactors,
                                                        secrets: secrets,
                                                        keyset: keyset)
            proofs.append(contentsOf: batchProofs)
        }
        currentCounter -= (emptyRuns + 1) * batchSize
        currentCounter += batchLastMatchIndex
        if currentCounter < 0 { currentCounter = 0 }
        return (proofs, proofs.count, currentCounter)
    }
    
    public func check(_ proofs:[Proof]) async throws -> [Proof.ProofState] {
        guard try units(for: proofs).count == 1 else {
            fatalError("mixed input units to .chack() function.")
        }
        
        let ys = try proofs.map { proof in
            try Crypto.secureHashToCurve(message: proof.secret).stringRepresentation
        }
        let request = Proof.StateCheckRequest(Ys: ys)
        let response = try await Network.post(url: self.url.appending(path: "/v1/checkstate"),
                                              body: request,
                                              expected: Proof.StateCheckResponse.self)
        return response.states.map { entry in
            entry.state
        }
    }
    
    // MARK: - MISC
    
    func activeKeysetForUnit(_ unit:String) -> Keyset? {
        self.keysets.first(where: {
            $0.active == true &&
            $0.unit == unit
        })
    }
    
    func units(for proofs:[Proof]) throws -> Set<String> {
        var units:Set<String> = []
        for proof in proofs {
            if let keysetForID = self.keysets.first(where: { $0.id == proof.id }) {
                units.insert(keysetForID.unit)
            } else {
                // found a proof that belongs to a keyset not from this mint
                fatalError("proofs from keysets that do not belong to this mint")
            }
        }
        return units
    }
}

public enum Cashu {
    public enum DuplicateOutputHandling {
        case fail
        case retry(Int)
        case infiniteRetry
        // potentially use /restore endpoint for efficiency
    }
}

extension Array where Element == Mint {
    public func restore(with seed:String, batchSize:Int = 10) async throws -> [Proof] {
        // call mint.restore on each of the mints
        fatalError()
    }
    
    public func getQuote(request:QuoteRequest) async throws -> [Quote] {
        // intended for melt quote request before MPP
        fatalError()
    }
    
    public func melt(quote:Quote, proofs:[Proof]) async throws -> [Proof] {
        // intended for multi nut payment (MPP)
        // check input proofs against mint info and keysets
        // make sure quote is Bolt11
        fatalError()
    }
}

extension Array where Element == Proof {
    public func select(amount: Int) -> (selected: [Proof], rest: [Proof])? {
        func backtrack(_ index: Int, _ currentSum: Int, _ currentSelection: [Proof]) -> [Proof]? {
            if currentSum == amount {
                return currentSelection
            }
            if index >= self.count || currentSum > amount {
                return nil
            }
            
            if let result = backtrack(index + 1, currentSum + self[index].amount, currentSelection + [self[index]]) {
                return result
            }
            return backtrack(index + 1, currentSum, currentSelection)
        }
        
        if let selected = backtrack(0, 0, []) {
            let rest = self.filter { !selected.contains($0) }
            return (selected, rest)
        }
        
        return nil
    }
    
    var sum:Int {
        self.reduce(0) { $0 + $1.amount }
    }
}
