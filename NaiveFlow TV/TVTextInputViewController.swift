import UIKit

class TVTextInputViewController: UIViewController {

    private let titleText: String
    private let currentValue: String
    private let placeholder: String
    private let onDone: (String) -> Void

    private let textField = UITextField()

    init(title: String, currentValue: String, placeholder: String, onDone: @escaping (String) -> Void) {
        self.titleText = title
        self.currentValue = currentValue
        self.placeholder = placeholder
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = titleText

        textField.text = currentValue
        textField.placeholder = placeholder
        textField.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: DesignSystem.TextRole.body.size))
        textField.adjustsFontForContentSizeCategory = true
        textField.borderStyle = .roundedRect
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.keyboardType = .URL
        textField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            textField.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -60),
            textField.widthAnchor.constraint(equalToConstant: 800),
        ])

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textField.becomeFirstResponder()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        onDone(textField.text ?? "")
        dismiss(animated: true)
    }
}
