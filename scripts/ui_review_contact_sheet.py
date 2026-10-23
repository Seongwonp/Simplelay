"""Make local-only contact sheets from Flutter golden review renders (requires Pillow)."""
from pathlib import Path
import argparse
from PIL import Image, ImageDraw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    files = sorted(args.source.glob('*_testImage.png'))
    args.output.mkdir(parents=True, exist_ok=True)
    for page in range(0, len(files), 15):
        sheet = Image.new('RGB', (1200, 1665), '#dddddd')
        draw = ImageDraw.Draw(sheet)
        for i, path in enumerate(files[page:page + 15]):
            x, y = i % 5 * 240, i // 5 * 555
            draw.text((x + 4, y + 4), path.name.removesuffix('_testImage.png'), fill='black')
            with Image.open(path) as frame:
                frame.thumbnail((236, 525))
                sheet.paste(frame, (x + 2, y + 26))
        sheet.save(args.output / f'review-{page // 15 + 1}.png')
    print(f'{len(files)} renders, {(len(files) + 14) // 15} sheets: {args.output}')


if __name__ == '__main__':
    main()
