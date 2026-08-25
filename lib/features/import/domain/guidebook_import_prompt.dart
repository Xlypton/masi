/// The prompt the user pastes into ChatGPT/Claude alongside a photo of a
/// guidebook page.
///
/// This is the whole "bring your own AI" mechanism: Masi never calls a model,
/// so this text is the entire interface between the user's chat subscription
/// and the app. Inference happens in their session, billed to them.
///
/// Two things in here are load-bearing and must not be softened:
///
///  - **Both photos, and coordinates against the user's own photo.** A model
///    given only the book page will happily emit coordinates for the book's
///    picture, which are meaningless on a photo taken from a different angle
///    at a different distance. Every line placed that way lands wrong.
///  - **Omit `points` rather than guess.** An honestly absent line becomes a
///    route the user draws in a few seconds. An invented one has to be found
///    and dragged back from somewhere wrong, which is slower than drawing it.
///
/// The worked example below is parsed by the production decoder in
/// `test/features/import/guidebook_import_prompt_test.dart`, so this text
/// cannot drift away from what the app actually accepts.
library;

/// The example payload embedded in [kGuidebookImportPrompt].
///
/// Kept as its own constant so the test can decode exactly the bytes the user
/// will see, rather than a re-typed copy that could silently disagree.
const String kGuidebookImportPromptExample = '''
{
  "v": 1,
  "boulder": "Cul de Chien",
  "gradeSystem": "french",
  "routes": [
    {
      "name": "Le Toit",
      "gradeRaw": "6a+",
      "stars": 2,
      "description": "Sit start, undercling out to the lip.",
      "positionHint": "leftmost line, up the obvious arete",
      "points": [[0.21, 0.94], [0.24, 0.55], [0.22, 0.16]]
    },
    {
      "name": "La Marie-Rose",
      "gradeRaw": "6a",
      "stars": 3,
      "description": "The classic. Crimps to a high finish.",
      "positionHint": "centre of the face, right of the arete"
    }
  ]
}''';

/// The full copy-paste prompt.
const String kGuidebookImportPrompt = '''
You are helping me import a bouldering guidebook page into Masi, a topo app.

I am giving you TWO images:
  1. A photo of a page from a printed guidebook.
  2. MY OWN photo of the same boulder.

Read the route information off the guidebook page, then reply with ONE JSON
object and nothing else — no explanation, no markdown fences.

Schema:
  v            always the number 1
  boulder      the boulder or sector name from the page, if it gives one
  gradeSystem  "french" or "uiaa" — whichever ladder the book uses.
               Font grades (6a, 7b+) are "french". Omit if you are unsure.
  routes       an array, in left-to-right order as they appear on the rock:
    name           the route name
    gradeRaw       the grade exactly as printed, e.g. "6a+"
    stars          quality 0-3, if the book shows it
    description    the book's description of the climb, in your own words
    positionHint   a short phrase telling me where the line sits on the rock,
                   e.g. "leftmost, up the obvious arete"
    points         OPTIONAL. The line, as [x, y] pairs from bottom to top.

About "points" — this is the part that matters most:

  Coordinates are fractions of MY photo, NOT the guidebook's picture.
  [0, 0] is the top-left of MY photo and [1, 1] is the bottom-right.
  So a line starting low-left and finishing top-centre looks like
  [[0.2, 0.95], [0.3, 0.5], [0.45, 0.1]].

  Look at the guidebook's drawn line, find that same feature on MY photo, and
  place the points there. Three or four points is plenty — a rough line in
  roughly the right place is genuinely useful, because I can drag it.

  If you cannot confidently match a route to a feature in MY photo, OMIT the
  "points" field for that route. Do not guess. A missing line takes me seconds
  to draw; a wrong one takes longer to find and fix than drawing it would.

Do not invent routes that are not on the page, and do not invent grades. If
the page is partly unreadable, include the routes you can read and leave the
rest out.

Example reply:

$kGuidebookImportPromptExample
''';
