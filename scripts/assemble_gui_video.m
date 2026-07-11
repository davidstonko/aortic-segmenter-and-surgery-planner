function out_path = assemble_gui_video()
%ASSEMBLE_GUI_VIDEO  Build MP4 from frames captured by capture_gui_frames().
%   Each step's frame gets ~3 seconds in the output. Caption banner is
%   composited on top.

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    cd(proj);

    S = load(fullfile(proj, 'results', 'videos', 'gui_frames.mat'));
    frames = S.frames;
    if isempty(frames); error('No frames found.'); end

    out_path = fullfile(proj, 'results', 'videos', 'evar_gui_walkthrough.mp4');
    if isfile(out_path); delete(out_path); end

    img0 = frames{1}.img;
    H = size(img0, 1); W = size(img0, 2);
    fps = 8;
    seconds_per_step = 3;

    vw = VideoWriter(out_path, 'MPEG-4');
    vw.FrameRate = fps;
    vw.Quality   = 85;
    open(vw);

    % H.264 needs even dimensions; pre-compute the target size and force
    % every captured frame to it via imresize. This avoids 'Frame must
    % be N by M' errors when getframe returns slightly-different sizes.
    target_W = 2 * floor(W / 2);
    target_H = 2 * floor(H / 2);
    for k = 1:numel(frames)
        img = frames{k}.img;
        if size(img, 1) ~= target_H || size(img, 2) ~= target_W
            img = imresize(img, [target_H, target_W]);
        end
        % Composite caption directly on the pixel buffer (no helper figure)
        caption = frames{k}.caption;
        banner_h = 46;
        img_with_banner = img;
        img_with_banner(target_H-banner_h+1:end, :, 1) = uint8(0.07 * 255);
        img_with_banner(target_H-banner_h+1:end, :, 2) = uint8(0.10 * 255);
        img_with_banner(target_H-banner_h+1:end, :, 3) = uint8(0.18 * 255);
        % Burn the caption text into the image via insertText
        try
            img_with_banner = insertText(img_with_banner, ...
                [target_W/2, target_H - 23], caption, ...
                'AnchorPoint', 'Center', 'TextColor', 'white', ...
                'BoxColor', [18, 25, 46], 'BoxOpacity', 1, ...
                'FontSize', 18);
        catch
            % insertText needs CVT — fall back silently
        end
        for n = 1:max(1, round(fps * seconds_per_step))
            writeVideo(vw, img_with_banner);
        end
    end
    close(vw);
    d = dir(out_path);
    fprintf('Wrote %s  (%.1f MB, %.0f s total)\n', out_path, d.bytes/1e6, ...
        numel(frames) * seconds_per_step);
end
