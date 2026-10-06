"""Builds the fictional demo dossier in examples/demo-dossier/ (English), used for the README screenshots
and to try HintMeet without your own files. All companies, people and amounts are made up.

    python examples/make_demo.py
    python tools/kb_prep.py examples/demo-dossier --project demo     # → ~/KB_md/demo/
"""
from __future__ import annotations

from email.message import EmailMessage
from pathlib import Path

OUT = Path(__file__).parent / "demo-dossier"


def purchase_agreement(path: Path) -> None:
    from docx import Document
    d = Document()
    d.add_heading("Asset Purchase Agreement – Harbor platform", 0)
    d.add_paragraph("Parties: Brightwave Software BV (seller) and Northwind Systems Ltd (buyer). Signed 14 March 2026.")
    d.add_heading("1. Purchase price", 1)
    d.add_paragraph("The total purchase price is EUR 600,000, consisting of EUR 400,000 for the Harbor software "
                    "and related intellectual property, and EUR 200,000 for the system management activities.")
    d.add_paragraph("The earlier draft price of EUR 650,000 for the software alone (draft of 2 February 2026) "
                    "is superseded and no longer applies.")
    d.add_heading("2. Payment", 1)
    d.add_paragraph("The purchase price is payable in one instalment on 1 July 2026. Title to the software and "
                    "the intellectual property passes on payment.")
    d.add_heading("3. System management", 1)
    d.add_paragraph("Brightwave keeps operating the system management until 31 December 2026 under a separate "
                    "service agreement at EUR 4,500 per month; staff transfer to Northwind on 1 January 2027.")
    d.add_heading("4. Warranties", 1)
    d.add_paragraph("Brightwave warrants that it is the sole owner of the Harbor source code. Open-source "
                    "components are listed in Annex B. Warranty claims expire 18 months after closing.")
    d.save(path)


def valuation_memo(path: Path) -> None:
    import pymupdf
    pages = [
        ("Valuation memo – Harbor platform (8 March 2026)",
         "Prepared for Brightwave Software BV.\n\nConclusion: the Harbor software and IP are valued at EUR 400,000. "
         "The system management activities are valued separately at EUR 200,000."),
        ("Method",
         "Cost approach: rebuild cost EUR 283,000 (2,100 developer hours).\nIncome approach: relief-from-royalty "
         "range EUR 380,000 – 502,000.\nThe chosen value of EUR 400,000 lies within both ranges."),
        ("Risks",
         "The tax inspector may argue for a higher value at the top of the royalty range. The order volumes behind "
         "the royalty range have not been documented yet; doing so before 1 July 2026 is recommended."),
    ]
    doc = pymupdf.open()
    for title, body in pages:
        page = doc.new_page()
        page.insert_text((72, 80), title, fontsize=16)
        page.insert_textbox(pymupdf.Rect(72, 110, 520, 760), body, fontsize=11)
    doc.save(path)


def scanned_loan(path: Path) -> None:
    """A scan: pages are images only, so kb_prep has to OCR them (shows progress per page)."""
    import pymupdf
    from PIL import Image, ImageDraw, ImageFont
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 34)
    texts = [
        "LOAN AGREEMENT\n\nNorthwind Systems Ltd lends\nBrightwave Software BV\nEUR 250,000 at 5.5% interest.\n\nDated 20 January 2026.",
        "Article 1 – Repayment\n\nThe loan is repaid from the\npurchase price of the Harbor\nplatform.",
        "Article 2 – Security\n\nNorthwind receives a pledge on\nthe Harbor source code until\nfull repayment.",
        "ADDENDUM 10 April 2026\n\nThe loan of EUR 250,000 is\nCANCELLED by mutual agreement.\nNo amount was ever paid out.",
        "The parties confirm that no\ninterest is due and that the\npledge on the source code\nlapses.",
        "Signed:\n\nBrightwave Software BV\nNorthwind Systems Ltd",
    ]
    doc = pymupdf.open()
    tmp = path.with_suffix(".jpg")   # jpeg in grijstinten: een scan van een paar honderd kB, niet tientallen MB
    for text in texts:
        img = Image.new("L", (1240, 1754), "white")
        ImageDraw.Draw(img).multiline_text((120, 160), text, fill="black", font=font, spacing=18)
        img.save(tmp, quality=60)
        page = doc.new_page(width=595, height=842)
        page.insert_image(page.rect, filename=str(tmp))
    tmp.unlink()
    doc.save(path)


def vat_mail(path: Path) -> None:
    msg = EmailMessage()
    msg["From"] = "Laura Chen <cfo@brightwave.example>"
    msg["To"] = "Stefan <stefan@brightwave.example>"
    msg["Date"] = "Tue, 24 Mar 2026 09:12:00 +0100"
    msg["Subject"] = "VAT on the Harbor sale"
    msg.set_content("Hi Stefan,\n\nOur tax advisor confirms: the sale of the Harbor platform qualifies as a transfer "
                    "of a going concern, so no VAT is charged on the EUR 600,000. Northwind continues the activity "
                    "with the same customers.\n\nThe system management service agreement (EUR 4,500 per month) is "
                    "subject to 21% VAT.\n\nBest,\nLaura")
    path.write_bytes(bytes(msg))


def cap_table(path: Path) -> None:
    from openpyxl import Workbook
    wb = Workbook()
    ws = wb.active
    ws.title = "Cap table"
    for row in [("Shareholder", "Shares", "Percentage", "Class"),
                ("Stefan (founder)", 6600, "66.0%", "ordinary"),
                ("Ravi (co-founder)", 2850, "28.5%", "ordinary"),
                ("Three angel investors", 550, "5.5%", "ordinary"),
                ("Total", 10000, "100%", "")]:
        ws.append(row)
    wb.save(path)


def shareholder_note(path: Path) -> None:
    path.write_text("""# Shareholders' agreement – key points

- Share premium of EUR 800,000 paid in by the founder in April 2026 belongs economically to the founder only
  (article 4.3); the three angel investors (together 5.5%) have no claim on it.
- Transfers of shares need approval of a two-thirds majority (article 17).
- Drag-along applies above a valuation of EUR 5 million.
""", encoding="utf-8")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    purchase_agreement(OUT / "01-purchase-agreement.docx")
    valuation_memo(OUT / "02-valuation-memo.pdf")
    scanned_loan(OUT / "03-loan-agreement-scan.pdf")
    vat_mail(OUT / "04-vat-on-the-sale.eml")
    cap_table(OUT / "05-cap-table.xlsx")
    shareholder_note(OUT / "06-shareholders-agreement.md")
    print(f"Demo dossier in {OUT}")
