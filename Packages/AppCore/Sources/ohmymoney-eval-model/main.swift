import CoreCSV
import CoreKit
import CoreModel
import Foundation

// `make eval-model CSV=<folder>` — what the category model is worth on a CSV export of the
// application (промт, раздел 4).
//
// It prints metrics and nothing else: no category names, no notes, no amounts. This output is
// meant to be pasted into a report, and a report is read by somebody else.
//
// It writes nothing anywhere — no model file, no database, no journal.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
  FileHandle.standardError.write(
    Data("usage: ohmymoney-eval-model <folder of the CSV export>\n".utf8))
  exit(2)
}
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)

do {
  // The owner's time zone, as the application reads the days of the operations.
  let export = try CSVExportReader(folder: folder, calendar: .system)
  let examples = export.examples()
  guard !examples.isEmpty else {
    FileHandle.standardError.write(
      Data("no labelled operations in that export: nothing to measure\n".utf8))
    exit(1)
  }
  let began = Date()
  let metrics = PrequentialEvaluation.run(on: examples)
  let milliseconds = Int((Date().timeIntervalSince(began) * 1000).rounded())
  print(EvaluationReport.text(of: metrics, milliseconds: milliseconds))
  print("")
  print(EvaluationReport.curve(of: examples))
} catch {
  FileHandle.standardError.write(Data("could not read the export: \(error)\n".utf8))
  exit(1)
}
