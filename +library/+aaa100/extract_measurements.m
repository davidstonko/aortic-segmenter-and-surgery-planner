function meas = extract_measurements(opts)
%LIBRARY.AAA100.EXTRACT_MEASUREMENTS  Derive radius profiles + EVAR
%   sizing measurements from the AAA-100 STL meshes + reference
%   centerlines.
%
%   meas = library.aaa100.extract_measurements()
%   meas = library.aaa100.extract_measurements(opts)
%
%   For each case:
%     - Loads the STL mesh (lumen-only).
%     - For each centerline point on each of the 5 vessels, computes
%       the inscribed sphere radius as the minimum 3-D distance to a
%       mesh vertex. (Approximation: uses vertices, not faces. For
%       this dataset the meshes are dense enough that the vertex-only
%       distance is a good radius estimate.)
%     - Derives EVAR sizing metrics from the aorta + iliac radius
%       profiles: proximal neck length, neck diameter, max AAA
%       diameter, distal iliac diameter.
%
%   Returns a 1xN struct array, one per case:
%       .case_id
%       .aorta_R, .iliac_L_R, ...        (N,1) radius per centerline node, mm
%       .aaa_max_diameter_mm             max(2*aorta_R)
%       .aaa_max_diameter_z              z-coord of the max
%       .neck_length_mm                  arc length from suprarenal level
%                                        to first node where R increases
%                                        by > 1.5x the suprarenal R
%                                        (rough proximal-neck estimator)
%       .neck_R_mm                       suprarenal aorta radius (median
%                                        of first 5 cranial-most nodes)
%       .iliac_L_distal_R_mm             radius at the distal-most iliac node
%       .iliac_R_distal_R_mm
%
%   OPTS:
%       .max_cases       default Inf — limit for quick smoke tests
%       .save_path       default <cache_root>/aaa100_measurements.mat
%       .mesh_dir        default <cache_root>/meshes
%       .verbose         default true

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'max_cases'); opts.max_cases = Inf; end
    if ~isfield(opts, 'save_path'); opts.save_path = ...
        fullfile(library.aaa100.cache_root(), 'aaa100_measurements.mat'); end
    if ~isfield(opts, 'mesh_dir');  opts.mesh_dir = ...
        fullfile(library.aaa100.cache_root(), 'meshes'); end
    if ~isfield(opts, 'verbose');   opts.verbose = true; end

    cases = library.aaa100.load_all();
    n_total = min(numel(cases), opts.max_cases);
    meas = [];
    vessels = {'aorta', 'iliac_L', 'iliac_R', 'renal_L', 'renal_R'};

    t0 = tic;
    for i = 1:n_total
        c = cases(i);
        stl_path = fullfile(opts.mesh_dir, [c.case_id '.stl']);
        if ~isfile(stl_path)
            if opts.verbose
                fprintf('  %s: STL missing — skipping\n', c.case_id);
            end
            continue;
        end
        verts = read_stl_vertices(stl_path);
        if isempty(verts)
            if opts.verbose
                fprintf('  %s: STL empty — skipping\n', c.case_id);
            end
            continue;
        end
        % kd-tree for nearest-neighbor queries
        Mdl = createns(verts, 'NSMethod', 'kdtree');

        entry = struct('case_id', c.case_id);
        for v = vessels
            P = c.(v{1});
            if isempty(P)
                entry.([v{1} '_R']) = [];
                continue;
            end
            [~, dist] = knnsearch(Mdl, P);
            entry.([v{1} '_R']) = dist;
        end

        % EVAR sizing — derived from the aorta radius profile.
        % The clinically-relevant proximal neck is BELOW the lowest renal
        % artery, not the top of the aorta. Use the renal ostium z as
        % the proximal landmark.
        Ra = entry.aorta_R;
        Pa = c.aorta;
        if numel(Ra) >= 5
            entry.aaa_max_diameter_mm = 2 * max(Ra);
            [~, idx_max] = max(Ra);
            entry.aaa_max_diameter_z = Pa(idx_max, 3);
            % Detect aorta orientation. AAA-100 aorta z decreases from
            % T12 (cranial-most) to the bifurcation (caudal-most). On
            % most cases Pa(1,3) > Pa(end,3) (proximal-first), but be
            % defensive.
            if Pa(1, 3) > Pa(end, 3)
                order = 1:numel(Ra);          % proximal → distal
            else
                order = numel(Ra):-1:1;
            end
            Ra_ord = Ra(order);
            Pa_ord = Pa(order, :);
            % Lowest renal ostium z: take node 1 of each renal centerline
            % (proximal end of renal = ostium on aorta). The "lowest" is
            % the MOST CAUDAL of the two (smaller z in patient coords
            % since z is cranial-positive in AAA-100). Use min(z).
            z_renal_L = NaN; z_renal_R = NaN;
            if size(c.renal_L, 1) > 0; z_renal_L = c.renal_L(1, 3); end
            if size(c.renal_R, 1) > 0; z_renal_R = c.renal_R(1, 3); end
            z_renal = min([z_renal_L, z_renal_R], [], 'omitnan');
            % Suprarenal neck radius: take the aorta node closest in
            % z to the lowest renal ostium. Use its R as the neck baseline.
            if ~isnan(z_renal)
                [~, k_renal] = min(abs(Pa_ord(:, 3) - z_renal));
            else
                k_renal = 1;     % fall back to cranial-most node
            end
            neck_R = median(Ra_ord(max(1, k_renal-1):min(numel(Ra_ord), k_renal+1)));
            entry.neck_R_mm = neck_R;
            % Proximal-neck length: walk distally from k_renal until R
            % exceeds 1.5 × neck_R (the start of the AAA bulge).
            neck_end = numel(Ra_ord);
            arc = 0;
            for k = k_renal+1:numel(Ra_ord)
                arc = arc + norm(Pa_ord(k, :) - Pa_ord(k-1, :));
                if Ra_ord(k) > 1.5 * neck_R
                    neck_end = k; break;
                end
            end
            if neck_end == k_renal
                entry.neck_length_mm = 0;
            else
                entry.neck_length_mm = sum(vecnorm(diff(Pa_ord(k_renal:neck_end, :)), 2, 2));
            end
        else
            entry.aaa_max_diameter_mm = NaN;
            entry.aaa_max_diameter_z = NaN;
            entry.neck_R_mm = NaN;
            entry.neck_length_mm = NaN;
        end

        % Iliac distal radius — sample at the 85th percentile of arc
        % rather than the very last node (the centerline endpoint sits
        % right at the mesh boundary, where the nearest-vertex distance
        % becomes vanishingly small).
        entry.iliac_L_distal_R_mm = distal_iliac_R(entry.iliac_L_R);
        entry.iliac_R_distal_R_mm = distal_iliac_R(entry.iliac_R_R);

        if isempty(meas); meas = entry;
        else;             meas(end+1) = entry; %#ok<AGROW>
        end

        if opts.verbose && (mod(i, 10) == 0 || i == n_total)
            fprintf('  %3d / %3d cases  (%.0fs elapsed)\n', i, n_total, toc(t0));
        end
    end

    save(opts.save_path, 'meas');
    fprintf('Saved %s (%d cases)\n', opts.save_path, numel(meas));

    % Cohort summary
    fprintf('\n--- AAA-100 derived measurements (cohort) ---\n');
    summarize('AAA max diameter (mm)', [meas.aaa_max_diameter_mm]);
    summarize('Proximal neck R (mm)',  [meas.neck_R_mm]);
    summarize('Proximal neck length (mm)', [meas.neck_length_mm]);
    summarize('L iliac distal R (mm)', [meas.iliac_L_distal_R_mm]);
    summarize('R iliac distal R (mm)', [meas.iliac_R_distal_R_mm]);
end

function V = read_stl_vertices(path)
% STL → unique vertex set. Uses the built-in stlread (R2018b+). Returns
% Nx3 double of vertex positions in mm.
    try
        TR = stlread(path);
        if isa(TR, 'triangulation')
            V = double(TR.Points);
        elseif isstruct(TR) && isfield(TR, 'Points')
            V = double(TR.Points);
        else
            V = [];
        end
    catch
        V = [];
    end
end

function R = distal_iliac_R(Rprofile)
    if isempty(Rprofile); R = NaN; return; end
    n = numel(Rprofile);
    if n < 4
        R = Rprofile(end);
    else
        k = max(1, round(0.85 * n));   % 85th percentile of arc
        R = Rprofile(k);
    end
end

function summarize(name, v)
    v = v(~isnan(v));
    if isempty(v); fprintf('  %-30s (no data)\n', name); return; end
    fprintf('  %-30s  median %6.1f  IQR [%5.1f, %5.1f]  range [%4.1f, %5.1f]\n', ...
        name, median(v), prctile(v, 25), prctile(v, 75), min(v), max(v));
end
