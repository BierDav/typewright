import Foundation

struct ProjectTemplate: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let body: (String) -> String

    static let all: [ProjectTemplate] = [
        ProjectTemplate(id: "blank", name: "Blank", symbol: "doc") { title in
            """
            = \(title)

            Start writing here.

            """
        },
        ProjectTemplate(id: "article", name: "Article", symbol: "doc.richtext") { title in
            """
            #set page(paper: "a4", numbering: "1")
            #set par(justify: true)
            #set heading(numbering: "1.1")

            #align(center)[
              #text(17pt, weight: "bold")[\(title)]

              Your Name \\
              #datetime.today().display()
            ]

            *Abstract.* #lorem(40)

            = Introduction
            #lorem(80)

            = Method
            #lorem(60)

            """
        },
        ProjectTemplate(id: "letter", name: "Letter", symbol: "envelope") { title in
            """
            #set page(paper: "a4", margin: 2.5cm)
            #set par(justify: true)

            Your Name \\
            Street 1 \\
            City

            #v(1cm)
            Recipient \\
            Street 2 \\
            City

            #align(right)[#datetime.today().display()]

            *\(title)*

            Dear Sir or Madam,

            #lorem(60)

            Kind regards, \\
            Your Name

            """
        },
        ProjectTemplate(id: "notes", name: "Notes", symbol: "list.bullet.rectangle") { title in
            """
            #set page(paper: "a4", columns: 2)
            #set text(size: 10pt)

            = \(title)

            == Ideas
            - First idea
            - Second idea

            == Math
            $ integral_0^1 x^2 dif x = 1/3 $

            """
        },
    ]
}
