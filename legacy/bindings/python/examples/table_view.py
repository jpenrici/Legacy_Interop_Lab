"""The ledger in a QTableView: the smallest useful PySide6 screen.

    bindings/python/.venv/bin/python bindings/python/examples/table_view.py
    ... --screenshot out.png      render offscreen (QT_QPA_PLATFORM=offscreen) and exit

It shows how the pieces fit: the controller owns the models, the table only
displays them, a delegate turns the model's NEGATIVE_ROLE hint into a colour,
and the Refresh button runs COBOL on a worker thread so the window never freezes.
"""

from __future__ import annotations

import sys

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (
    QApplication,
    QHeaderView,
    QLabel,
    QPushButton,
    QStyledItemDelegate,
    QTableView,
    QVBoxLayout,
    QWidget,
)

from legacy_ledger import format_cents
from legacy_ledger.qt import NEGATIVE_ROLE, LedgerController


class MoneyDelegate(QStyledItemDelegate):
    """Draws negative amounts in red. The model only says WHICH are negative."""

    def initStyleOption(self, option, index):
        super().initStyleOption(option, index)
        if index.data(NEGATIVE_ROLE):
            option.palette.setColor(option.palette.ColorRole.Text, QColor("#c0392b"))
            option.palette.setColor(
                option.palette.ColorRole.HighlightedText, QColor("#ffb3a7")
            )


class LedgerWindow(QWidget):
    def __init__(self, controller: LedgerController) -> None:
        super().__init__()
        self.setWindowTitle("Legacy ledger")
        self.controller = controller

        self.summary = QLabel("Press Refresh")
        self.button = QPushButton("Refresh")
        self.table = QTableView()
        self.table.setModel(controller.months_model)
        self.table.setItemDelegate(MoneyDelegate(self.table))
        self.table.setAlternatingRowColors(True)
        self.table.horizontalHeader().setSectionResizeMode(
            QHeaderView.ResizeMode.Stretch
        )

        layout = QVBoxLayout(self)
        layout.addWidget(self.summary)
        layout.addWidget(self.table)
        layout.addWidget(self.button)
        self.resize(820, 300)

        self.button.clicked.connect(controller.refresh_async)  # never blocks the window
        controller.busy_changed.connect(lambda busy: self.button.setDisabled(busy))
        controller.refreshed.connect(self.show_summary)
        controller.failed.connect(
            lambda message, log: self.summary.setText(f"Error: {message}\n{log}")
        )

    def show_summary(self, snapshot) -> None:
        s = snapshot.summary
        self.summary.setText(
            f"{s.months} months, balance {format_cents(s.balance_cents)}   |   "
            f"best {s.best_period} ({format_cents(s.best_cents)})   |   "
            f"worst {s.worst_period} ({format_cents(s.worst_cents)})"
        )


def main(argv: list[str]) -> int:
    app = QApplication(argv)
    controller = LedgerController(parent=app)
    window = LedgerWindow(controller)
    window.show()
    controller.refresh_async()  # first load, off the GUI thread

    if "--screenshot" in argv:
        path = argv[argv.index("--screenshot") + 1]
        controller.refreshed.connect(
            lambda _: QTimer.singleShot(
                0, lambda: (window.grab().save(path), app.quit())
            )
        )
        QTimer.singleShot(30000, app.quit)  # safety net
    code = app.exec()
    controller.wait()
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
