import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { execFileSync } from 'node:child_process';

function hasUnzipCli() {
	try {
		execFileSync('which', ['unzip'], { stdio: 'ignore' });
		return true;
	} catch {
		return false;
	}
}

/** Minimal ZIP reader (central directory + STORED/DEFLATE entries only). */
function extractZipPureNode(zipPath, destDir) {
	const buf = fs.readFileSync(zipPath);
	const eocdSig = 0x06054b50;
	let eocdOffset = -1;
	for (let i = buf.length - 22; i >= 0; i--) {
		if (buf.readUInt32LE(i) === eocdSig) {
			eocdOffset = i;
			break;
		}
	}
	if (eocdOffset === -1) throw new Error(`not a valid zip file: ${zipPath}`);

	const entryCount = buf.readUInt16LE(eocdOffset + 10);
	const cdOffset = buf.readUInt32LE(eocdOffset + 16);

	let offset = cdOffset;
	for (let i = 0; i < entryCount; i++) {
		const sig = buf.readUInt32LE(offset);
		if (sig !== 0x02014b50) throw new Error(`bad central directory entry at ${offset}`);
		const method = buf.readUInt16LE(offset + 10);
		const compSize = buf.readUInt32LE(offset + 20);
		const nameLen = buf.readUInt16LE(offset + 28);
		const extraLen = buf.readUInt16LE(offset + 30);
		const commentLen = buf.readUInt16LE(offset + 32);
		const localHeaderOffset = buf.readUInt32LE(offset + 42);
		const name = buf.toString('utf8', offset + 46, offset + 46 + nameLen);

		if (!name.endsWith('/')) {
			const lhSig = buf.readUInt32LE(localHeaderOffset);
			if (lhSig !== 0x04034b50) throw new Error(`bad local header for ${name}`);
			const lhNameLen = buf.readUInt16LE(localHeaderOffset + 26);
			const lhExtraLen = buf.readUInt16LE(localHeaderOffset + 28);
			const dataStart = localHeaderOffset + 30 + lhNameLen + lhExtraLen;
			const compData = buf.subarray(dataStart, dataStart + compSize);
			const data = method === 0 ? compData : zlib.inflateRawSync(compData);

			const outPath = path.join(destDir, name);
			fs.mkdirSync(path.dirname(outPath), { recursive: true });
			fs.writeFileSync(outPath, data);
		}

		offset += 46 + nameLen + extraLen + commentLen;
	}
}

function extractZip(zipPath, destDir) {
	fs.mkdirSync(destDir, { recursive: true });
	if (hasUnzipCli()) {
		execFileSync('unzip', ['-o', '-q', zipPath, '-d', destDir]);
	} else {
		extractZipPureNode(zipPath, destDir);
	}
}

/**
 * Downloads (with caching) and extracts a zip source.
 * @returns {Promise<{extractDir: string, sha256: string}>}
 */
export async function downloadAndExtract({ key, url, sha256, cacheDir }) {
	fs.mkdirSync(cacheDir, { recursive: true });
	const zipPath = path.join(cacheDir, `${key}.zip`);
	const extractDir = path.join(cacheDir, `${key}-extracted`);

	if (!fs.existsSync(zipPath)) {
		console.log(`[download] fetching ${key} <- ${url}`);
		const res = await fetch(url);
		if (!res.ok) throw new Error(`download failed for ${key}: HTTP ${res.status}`);
		const buf = Buffer.from(await res.arrayBuffer());
		fs.writeFileSync(zipPath, buf);
	} else {
		console.log(`[download] using cached ${path.relative(process.cwd(), zipPath)}`);
	}

	const actualSha256 = crypto.createHash('sha256').update(fs.readFileSync(zipPath)).digest('hex');
	if (sha256) {
		if (actualSha256 !== sha256) {
			throw new Error(
				`sha256 mismatch for ${key}: expected ${sha256}, got ${actualSha256}. ` +
					`Delete .geodata-cache/${key}.zip and retry, or update versions.mjs if the source changed intentionally.`
			);
		}
	} else {
		console.warn(
			`[download] no recorded sha256 for ${key}; observed ${actualSha256} — hardcode this into versions.mjs`
		);
	}

	if (!fs.existsSync(extractDir) || fs.readdirSync(extractDir).length === 0) {
		extractZip(zipPath, extractDir);
	}

	return { extractDir, sha256: actualSha256 };
}

export function findShapefile(dir) {
	const shp = fs.readdirSync(dir).find((f) => f.toLowerCase().endsWith('.shp'));
	if (!shp) throw new Error(`no .shp file found in ${dir}`);
	return path.join(dir, shp);
}
