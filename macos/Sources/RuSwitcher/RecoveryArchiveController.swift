import Foundation

/// Serial local export and verification. The input callback only schedules a
/// future main-loop turn; all archive I/O runs on the utility queue.
@MainActor
final class RecoveryArchiveController {
    typealias Directory = @Sendable () throws -> URL
    typealias Save = @Sendable ([RecoveryArchive.Source], URL) throws -> RecoveryArchive.Receipt
    typealias Validate = @Sendable (UUID, RecoveryArchive.Receipt) throws -> String

    private let converter: TextConverter
    private let enabled: @Sendable () -> Bool
    private let directory: Directory
    private let save: Save
    private let validate: Validate
    private let queue = DispatchQueue(label: "com.macswitcher.recovery-archive", qos: .utility)
    private var working = false
    private var pendingManual = false
    private var pendingAutomatic = false
    private var retry: DispatchWorkItem?
    private var retryUsed = false
    private var autoExhausted = false
    private var failedBatchIDs = Set<UUID>()
    private let retryDelay: TimeInterval
    var onSaved: (() -> Void)?
    var onFailure: ((Bool, RecoveryArchive.Failure) -> Void)?
    var onHeadroomPrepared: (() -> Void)?

    init(converter: TextConverter, enabled: @escaping @Sendable () -> Bool,
         directory: @escaping Directory,
         save: @escaping Save = { try RecoveryArchive.saveVerified($0, in: $1) },
         validate: @escaping Validate = { try RecoveryArchive.original(id: $0, receipt: $1) },
         retryDelay: TimeInterval = 30) {
        self.converter = converter
        self.enabled = enabled
        self.directory = directory
        self.save = save
        self.validate = validate
        self.retryDelay = retryDelay
    }

    func scheduleAutomaticAfterCurrentEvent() {
        DispatchQueue.main.async { [weak self] in self?.requestAutomatic() }
    }

    func settingChanged(_ isEnabled: Bool) {
        if isEnabled {
            scheduleAutomaticAfterCurrentEvent()
        } else {
            retry?.cancel(); retry = nil
            pendingAutomatic = false
        }
    }

    func requestAutomatic() {
        guard enabled() else { return }
        let originals = converter.unbackedOriginals.map { RecoveryArchive.Source(id: $0.id, text: $0.text) }
        guard !originals.isEmpty else { return }
        let ids = Set(originals.map(\.id))
        if ids != failedBatchIDs {
            failedBatchIDs = ids
            retryUsed = false
            autoExhausted = false
            retry?.cancel(); retry = nil
        }
        guard retry == nil, !autoExhausted else { return }
        if working { pendingAutomatic = true; return }
        beginSave(originals, manual: false)
    }

    func requestManual() {
        if working { pendingManual = true; return }
        let backed = converter.backedOriginals
        guard !backed.isEmpty else { beginManualSave(); return }
        working = true
        let validate = self.validate
        queue.async { [weak self] in
            let invalid = backed.filter { (try? validate($0.id, $0.archive)) != $0.text }
            DispatchQueue.main.async { self?.finishManualValidation(invalid) }
        }
    }

    private func finishManualValidation(_ invalid: [TextConverter.BackedOriginal]) {
        for source in invalid { converter.invalidateBacking(id: source.id, receipt: source.archive) }
        working = false
        beginManualSave()
    }

    private func beginManualSave() {
        let originals = converter.unbackedOriginals.map { RecoveryArchive.Source(id: $0.id, text: $0.text) }
        if originals.isEmpty {
            if beginHeadroomValidation() { return }
            onSaved?(); drain(); return
        }
        beginSave(originals, manual: true)
    }

    private func beginSave(_ originals: [RecoveryArchive.Source], manual: Bool) {
        working = true
        let directory = self.directory, save = self.save, enabled = self.enabled
        queue.async { [weak self] in
            guard manual || enabled() else {
                DispatchQueue.main.async { self?.finishSave(.success(nil), originals: originals, manual: false) }
                return
            }
            let outcome: Result<RecoveryArchive.Receipt?, RecoveryArchive.Failure>
            do { outcome = .success(try save(originals, directory())) }
            catch let failure as RecoveryArchive.Failure { outcome = .failure(failure) }
            catch { outcome = .failure(.writeFailed) }
            DispatchQueue.main.async { self?.finishSave(outcome, originals: originals, manual: manual) }
        }
    }

    private func finishSave(_ outcome: Result<RecoveryArchive.Receipt?, RecoveryArchive.Failure>,
                            originals: [RecoveryArchive.Source], manual: Bool) {
        working = false
        switch outcome {
        case .success(nil): break // disabled before the utility worker started
        case .success(let receipt?):
            if converter.markArchived(receipt) {
                onSaved?()
                if beginHeadroomValidation() { return }
                clearFailureState()
            } else {
                let pending = Set(converter.unbackedOriginals.map(\.id))
                if originals.contains(where: { pending.contains($0.id) }) {
                    failed(manual: manual, reason: .verificationFailed)
                }
            }
        case .failure(let reason): failed(manual: manual, reason: reason)
        }
        drain()
    }

    /// Validate an existing archive off-main immediately before releasing its
    /// only RAM original. Leave newer backed records available for gesture undo.
    @discardableResult
    private func beginHeadroomValidation() -> Bool {
        guard !working, converter.needsRecoveryHeadroom,
              let oldest = converter.backedOriginals.first else { return false }
        working = true
        let validate = self.validate
        queue.async { [weak self] in
            let valid = (try? validate(oldest.id, oldest.archive)) == oldest.text
            DispatchQueue.main.async { self?.finishHeadroomValidation(oldest, valid: valid) }
        }
        return true
    }

    private func finishHeadroomValidation(_ source: TextConverter.BackedOriginal, valid: Bool) {
        working = false
        if valid {
            _ = converter.evictValidatedBacking(id: source.id, receipt: source.archive)
            onHeadroomPrepared?()
            if beginHeadroomValidation() { return }
            clearFailureState()
        } else {
            converter.invalidateBacking(id: source.id, receipt: source.archive)
            failedBatchIDs = Set(converter.unbackedOriginals.map(\.id))
            failed(manual: false, reason: .verificationFailed)
        }
        drain()
    }

    private func clearFailureState() {
        retry?.cancel(); retry = nil
        retryUsed = false; autoExhausted = false
    }

    private func failed(manual: Bool, reason: RecoveryArchive.Failure) {
        onFailure?(manual, reason)
        guard !manual, enabled() else { return }
        if retryUsed { autoExhausted = true; return }
        retryUsed = true
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retry = nil
            self.requestAutomatic()
        }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: item)
    }

    private func drain() {
        if pendingManual {
            pendingManual = false
            requestManual()
        } else if pendingAutomatic || (enabled() && !converter.unbackedOriginals.isEmpty) {
            pendingAutomatic = false
            requestAutomatic()
        }
    }
}
