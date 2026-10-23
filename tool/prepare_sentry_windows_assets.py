"""Append matched Native Assets/helper PDBs to the CMake target inventory."""
from pathlib import Path
import shutil
from sentry_hook_inputs import rust_inputs
from upload_sentry_symbols import SymbolError, check_symbol, fingerprint


def prepare_windows_assets(build_root: Path, cli: str):
    root = build_root.resolve()
    manifests = list(root.glob('**/sentry-symbols/Release/targets.tsv'))
    if len(manifests) != 1:
        raise SymbolError('Expected one fresh Windows target inventory')
    manifest = manifests[0]
    rows = [row.split('\t') for row in manifest.read_text(encoding='utf-8').splitlines()]
    runner = [row for row in rows if len(row) == 3 and row[0] in {'FlClash','OmoFly','Daishu'}]
    if len(runner) == 1: runner[0][0] = 'FlClash' # Stable logical role; actual PE/PDB names stay intact.
    if len(runner) != 1:
        raise SymbolError('Windows runner inventory is missing')
    bundle = Path(runner[0][1]).resolve().parent
    if not bundle.is_relative_to(root):
        raise SymbolError('Windows runner escaped build root')
    rust = rust_inputs(root, 'windows')
    if len(rust) != 1 or rust[0]['architecture'] != 'x64':
        raise SymbolError('Expected one matching x64 Rust Native Assets record')
    record = rust[0]
    installed = bundle / 'rust_api.dll'
    if not installed.is_file() or fingerprint(installed)['sha256'] != fingerprint(record['binary'])['sha256']:
        raise SymbolError('Rust Native Assets does not match final Windows bundle')
    pdb = [p for p in record['companions'] if p.suffix == '.pdb']
    if len(pdb) != 1:
        raise SymbolError('Rust Native Assets PDB missing')
    architecture = check_symbol(cli, Path(runner[0][1]), 'pe')['architectures']
    if architecture != ['x86_64']:
        raise SymbolError('Windows release runner must be x64')
    def paired(binary, debug):
        runtime_info, debug_info = check_symbol(cli, binary, 'pe'), check_symbol(cli, debug, 'pdb')
        if runtime_info['debug_ids'] != debug_info['debug_ids']:
            raise SymbolError('Windows Native Assets binary/PDB mismatch')
        if runtime_info['architectures'] != architecture or debug_info['architectures'] != architecture:
            raise SymbolError('Windows native module architecture differs from runner')
    paired(installed, pdb[0])
    additions = [['rust_api', str(installed), str(pdb[0])]]
    helper = bundle / (Path(runner[0][1]).stem + 'HelperService.exe')
    if not helper.is_file():
        raise SymbolError('Windows helper missing from final bundle')
    helper_id = check_symbol(cli, helper, 'pe')['debug_ids']
    candidates = list((root.parent / 'services/helper/target').glob('*/release/helper.pdb'))
    matches = [p for p in candidates if not p.is_symlink() and check_symbol(cli, p, 'pdb')['debug_ids'] == helper_id]
    if len(matches) != 1:
        raise SymbolError('Windows helper requires one matching private PDB')
    destination = root / 'sentry-hook-inputs/windows/helper/helper.pdb'
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(matches[0], destination)
    paired(helper, destination)
    additions.append(['FlClashHelperService', str(helper), str(destination)])
    rows = [row for row in rows if row[0] not in {'rust_api','FlClashHelperService'}]
    manifest.write_text(''.join('\t'.join(row)+'\n' for row in rows+additions), encoding='utf-8', newline='\n')
