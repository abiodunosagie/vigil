import Foundation

/// Sends the same alerts to a phone through ntfy (https://ntfy.sh): the user installs the ntfy
/// app and subscribes to the topic shown in Settings. No account. Only the title and body of
/// the alert are sent, never anything else.
enum PhoneAlerts {
    static func send(title: String, body: String, to url: URL, completion: (@Sendable (Bool) -> Void)? = nil) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        // ntfy reads the title from this header; HTTP headers must be plain ASCII.
        request.setValue(String(title.unicodeScalars.filter(\.isASCII)), forHTTPHeaderField: "Title")
        request.httpBody = Data(body.utf8)
        URLSession.shared.dataTask(with: request) { _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
            if !ok { NSLog("Vigil phone alert not sent") }
            completion?(ok)
        }.resume()
    }
}
