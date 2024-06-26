function [x_out, output] = genHyBR_Separ(A, b, Q, R, mask, options)
%
% [x_out, output] = genHyBR_Separ(A, b, Q, R, options)
%
% genHyBR is a generalized Hybrid Bidiagonalization Regularization method used for
% solving large-scale, ill-posed inverse problems of the form:
%               b = A*x + noise
% The method combines an iterative generalize Golub-Kahan (GK) Bidiagonalization Method
% with a SVD-based regularization method to stabilize the semiconvergence
% behavior that is characteristic of many ill-posed problems.
%
% Inputs:
%     A : either (a) a full or sparse matrix
%                (b) a matrix object that performs mat*vec and mat'*vec
%         Note: If A is a function handle, create an object called funMat
%         e.g., A = funMat(Afun, Atfun) where Afun and Atfun are function
%                                       handles for A*vec and A'*vec
%     b : rhs vector
%  Q, R : covariance matrices, Q is either (a) a full or sparse matrix or
%                (b) a matrix object that performs matrix*vector operations
%         Note: If Q is a function handle, create an object called funMat
%         e.g., Q = funMat(Qfun, Qtfun) where Qfun and Qtfun are function
%                                       handles for Q*vec and Q'*vec
%
% options : structure with the following fields (optional)
%         InSolv - solver for the inner problem: [none | TSVD | {Tikhonov}]
%         RegPar - a value or method to find the regularization parameter:
%                       [non-negative scalar | DP | GCV | {WGCV} | optimal]
%                   Note: 'optimal' requires x_true
%         nLevel - if RegPar is 'DP', then nLevel represents the noise level and must be
%                       [non-negative scalar | {est}]
%          Omega - if RegPar is 'WGCV', then omega must be
%                       [non-negative scalar | {adapt}]
%           Iter - maximum number of GK iterations:
%                       [ positive integer | {min(m,n,100)} ]
%         Reorth - reorthogonalize Lanczos subspaces: [on | {off}]
%         x_true - True solution : [ array | {off} ]
%                Returns error norms with respect to x_true at each iteration
%                and is used to compute 'optimal' regularization parameters
%         BegReg - Begin regularization after this iteration:
%                   [ positive integer | {2} ]
%             Vx - extra space needed for finding optimal reg. parameters
%        FlatTol - Tolerance for detecting flatness in the GCV curve as a
%                    stopping criteria
%                   [ non-negative scalar | {10^-6}]
%         MinTol - Window of iterations for detecting a minimum of the GCV curve
%                    as a stopping criteria
%                   [ positive integer | {3}]
%         ResTol - Residual tolerance for stopping the LBD iterations,
%                    similar to the stopping criteria from [1]: [atol, btol]
%                   [non-negative scalar  | {[10^-6, 10^-6]}]
%
%       Note: options is a structure created using the function 'HyBRset'
%               (see 'HyBRset' for more details)
%
% Outputs:
%      x_out : computed solution
%     output : structure with the following fields:
%      iterations - stopping iteration (options.Iter | GCV-determined)
%         GCVstop - GCV curve used to find stopping iteration
%            Enrm - relative error norms (requires x_true)
%            Rnrm - relative residual norms
%            Xnrm - relative solution norms
%            U,QV - U and V are genGK basis vectors and Q is from the prior
%               B - bidiagonal matrix from genGK
%            flag - a flag that describes the output/stopping condition:
%                       1 - flat GCV curve
%                       2 - min of GCV curve (within window of MinTol its)
%                       3 - performed max number of iterations
%                       4 - achieved residual tolerance
%           alpha - regularization parameter at (output.iterations) its
%           Alpha - vector of all regularization parameters computed
%
% References:
%   [1] Paige and Saunders, "LSQR an algorithm for sparse linear
%       equations an sparse least squares", ACM Trans. Math Software,
%       8 (1982), pp. 43-71.
%   [2] Bjorck, Grimme and Van Dooren, "An implicit shift bidiagonalization
%       algorithm for ill-posed systems", BIT 34 (11994), pp. 520-534.
%   [3] Chung, Nagy and O'Leary, "A Weighted-GCV Method for Lanczos-Hybrid
%       Regularization", ETNA 28 (2008), pp. 149-167.
%   [4] Chung and Saibaba. "Generalized Hybrid Iterative Methods for 
%       Large-Scale Bayesian Inverse Problems", submitted 2016
%
% J.Chung and J. Nagy 3/2007
% J. Chung and A. Saibaba, modified 1/2016
% Modified by M. Sabate Landman 7/2024

%% Initialization
defaultopt = struct('InSolv','tikhonov','RegPar','wgcv','nLevel', 'est',...
  'Omega', 'adapt', 'Iter', [] , 'Reorth', 'off', 'x_true', 'off', 'BegReg', 2,...
  'Vx' , [], 'FlatTol', 10^-6, 'MinTol', 10, 'ResTol', [10^-6, 10^-6],'mask','off');

% If input is 'defaults,' return the default options in x_out
if nargin==1 && nargout <= 1 && isequal(A,'defaults')
  x_out = defaultopt;
  return;
end

% Check for acceptable number of input arguments
if nargin < 4
  error('genHyBR: Not Enough Inputs')
elseif nargin < 5
  options = [];
end
if isempty(options)
  options = defaultopt;
end

% Get options:
[m,n] = size(A);
defaultopt.Iter = min([m, n, 100]);
options = HyBR_lsmrset(defaultopt, options);

solver = HyBR_lsmrget(options,'InSolv',[],'fast');
regpar = HyBR_lsmrget(options,'RegPar',[],'fast');
nLevel = HyBR_lsmrget(options,'nLevel',[],'fast');
omega = HyBR_lsmrget(options,'Omega',[],'fast');
maxiter = HyBR_lsmrget(options,'Iter',[],'fast');
x_true = HyBR_lsmrget(options,'x_true',[],'fast');
regstart = HyBR_lsmrget(options,'BegReg',[],'fast');
degflat = HyBR_lsmrget(options,'FlatTol',[],'fast');
mintol = HyBR_lsmrget(options,'MinTol',[],'fast');
restol = HyBR_lsmrget(options,'ResTol',[],'fast');

adaptWGCV = strcmp(regpar, {'wgcv'}) && strcmp(omega, {'adapt'});
notrue = strcmp(x_true,{'off'});
nomask = strcmp(mask,{'off'});

if (strcmpi(regpar,'dp') ||strcmpi(regpar,'upre')) && strcmpi(nLevel,'est')
  % Estimate the noise level using finest wavelet coefficients
  if size(b,2) ==1 %1D
    [cA, cD] = dwt(b,'db1');
    nLevel = median(abs(cD(:)))/.67
    options = HyBR_lsmrset(options, 'nLevel', nLevel);
  else %2D
    [cA2,cH2,cV2,cD2] = dwt2(b,'db1');
    nLevel = median(abs(cD2(:)))/.67
    options = HyBR_lsmrset(options, 'nLevel', nLevel);
  end
end
%--------------------------------------------
%  The following is needed for RestoreTools:
if isa(A, 'psfMatrix')
  bSize = size(b);
  b = b(:);
  A.imsize = bSize;
  if ~notrue
    xTrueSize = size(x_true);
    x_true = x_true(:);
  end
end
%  End of new stuff needed for RestoreTools
%--------------------------------------------



% nbeta: length of beta (Mean Coefficient of Hierarchical Gaussian)
nbeta = A.nbeta;
% ntimes: number of temporal component of fluxes for each location
ntimes = A.n;
% nlocation: number of spatial component of fluxes at each time
nlocation = (size(A,2)-nbeta)/ntimes;

if ~notrue
    if nomask
        x_truemask = x_true;
    else
        x_truemask = x_true(mask);
    end
    nrmtruemask = norm(x_truemask(:));
end

% Set-up output parameters:
outputparams = nargout>1;
if outputparams
  output.iterations = maxiter;
  output.GCVstop = [];
  output.Enrm = ones(maxiter,1);
  output.Enrm_s = ones(maxiter,1);
   if nbeta ~= 0
    output.Enrm_b = ones(maxiter,1);
   end
  output.Enrm_ave = ones(maxiter,1);
  output.Rnrm = ones(maxiter,1);
  output.Xnrm = ones(maxiter,1);
  output.U = [];
  output.QV = [];
  output.B = [];
  output.flag = 3;
  output.alpha = 0;
  output.Alpha = [];
end

%Define GK bidiagonalization function
beta = normM(b,@(x)R\x);
U = (1 / beta)*b;
GKhandle = @genGKB;

switch solver
  case 'tsvd'
    solverhandle = @TSVDsolver;
  case 'tikhonov'
    % update: changed name of the solver for conflicting versions
    solverhandle = @Tikhonovsolver_genH;
    % solverhandle = @Tikhonovsolver;
end
%% Main Code Begins Here
B = []; V = []; QV = []; GCV = []; Omega= []; x_out = []; Alpha = [];
insolve = 'none'; terminate = 1; warning = 0; norma = 0; normr = beta;
h = waitbar(0, 'Beginning iterations: please wait ...');

for i = 1:maxiter+1 %Iteration (i=1) is just an initialization
  [U, B, V, QV] = feval(GKhandle, A, Q, R, U, B, V, QV, options);
  vector = (beta*eye(size(B,2)+1,1));
  
  if i >= 2 %Begin GK iterations
    if i >= regstart %Begin to regularize projected problem
      insolve = solver;
    end
    switch insolve
      case {'tsvd', 'tikhonov'}
        [Ub, Sb, Vb] = svd(B);
        
        if adaptWGCV %Use the adaptive, weighted GCV method
          Omega(i-1) = min(1, findomega(Ub'*vector, diag(Sb), insolve));
          options.Omega = mean(Omega);
        end
        
        % Solve the projected problem with Tikhonov or TSVD
        [f, alpha] = feval(solverhandle, Ub, diag(Sb), Vb, vector, options, B, beta, QV, m);
        %[f, alpha] = feval(solverhandle, Ub, diag(Sb), Vb, vector, options);
%         options.alpha = alpha;
        Alpha(i-1) = alpha;
        
        % Compute the GCV value used to find the stopping criteria
        GCV(i-1) = GCVstopfun(alpha, Ub(1,:)', diag(Sb), beta, m, n, insolve);
        
        % Determine if GCV wants us to stop
        if i > 2 && terminate
          %%-------- If GCV curve is flat, we stop -----------------------
          if abs((GCV(i-1)-GCV(i-2)))/GCV(regstart-1) < degflat
            %             x_out = V*f; % Return the solution at (i-1)st iteration
%             x_out = Q*(V*f); % Return the solution at (i-1)st iteration
            x_out = QV*f; % Return the solution at (i-1)st iteration
            
            if notrue %Set all the output parameters and return
              if outputparams % 
                output.U = []; %U;
                output.V = []; %V;
                output.QV = []; %QV;
                output.B = []; %B;
                output.GCVstop = GCV(:);
                output.iterations = i-1;
                output.flag = 1;
                output.alpha = alpha; % Reg Parameter at the (i-1)st iteration
                output.Alpha = Alpha(1:i-1); % Reg Parameters
              end
              close(h)
              %--------------------------------------------
              %  The following is needed for RestoreTools:
              %
              if isa(A, 'psfMatrix')
                x_out = reshape(x_out, bSize);
              end
              %
              %  End of new stuff needed for RestoreTools
              %--------------------------------------------
              return;
            else % Flat GCV curve means stop, but continue since have x_true
              if outputparams
                output.iterations = i-1; % GCV says stop at (i-1)st iteration
                output.flag = 1;
                output.alpha = alpha; % Reg Parameter at the (i-1)st iteration
              end
            end
            terminate = 0; % Solution is already found!
            
            %%--- Have warning : Avoid bumps in the GCV curve by using a
            %    window of (mintol+1) iterations --------------------
          elseif warning && length(GCV) > iterations_save + mintol %Passed window
            if GCV(iterations_save) < GCV(iterations_save+1:end)
              % We should have stopped at iterations_save.
              x_out = x_save;
              if notrue %Set all the output parameters and return
                  if outputparams
                      output.U = []; %U;
                      output.V = []; %V;
                      output.QV = []; %QV;
                      output.B = []; %B;
                      output.GCVstop = GCV(:);
                      output.iterations = iterations_save;
                      output.flag = 2;
                      output.alpha = alpha_save;
                      output.Alpha = Alpha(1:iterations_save); % Reg Parameters
                end
                close(h)
                %--------------------------------------------
                %  The following is needed for RestoreTools:
                %
                if isa(A, 'psfMatrix')
                  x_out = reshape(x_out, bSize);
                end
                %
                %  End of new stuff needed for RestoreTools
                %--------------------------------------------
                return;
              else % GCV says stop at iterations_save, but continue since have x_true
                if outputparams
                  output.iterations = iterations_save;
                  output.flag = 2;
                  output.alpha = alpha_save;
                end
              end
              terminate = 0; % Solution is already found!
              
            else % It was just a bump... keep going
              warning = 0;
              x_out = [];
              iterations_save = maxiter;
              alpha_save = 0;
            end
            
            %% ----- No warning yet: Check GCV function---------------------
          elseif ~warning
            if GCV(i-2) < GCV(i-1) %Potential minimum reached.
              warning = 1;
              % Save data just in case.
%               x_save = Q*(V*f);
              x_save = QV*f;
              iterations_save = i-1;
              alpha_save = alpha;
            end
          end
        end
        
      case 'none'
        f = B \ vector;
        alpha = 0;
      otherwise
        error('genHyBR error: No inner solver!')
    end
    %     x = Q*(V*f);
    x = QV*f;
    r = b(:) - A*x(:);
    normr = norm(r(:));
    if outputparams
        if ~notrue
            if nomask
                xmask = x(1:end-nbeta);
            else
                xmask = x(1:end-nbeta);
                xmask = xmask(mask);
            end
            output.Enrm(i,1) = norm(xmask(:)-x_truemask(:))/nrmtruemask;
            %output.Enrm(i,1) = norm(x(1:end-nbeta)-x_true(:))/nrmtrue;
            %output.Enrm(i,1) = norm(x(:)-x_true(:))/nrmtrue;
            %output.Enrm_s(i,1) = norm(x(1:end-nbeta)-x_true(1:end-nbeta))/nrmtrue_s;
            % if nbeta ~= 0
            %     output.Enrm_b(i,1) = norm(x(end-nbeta+1:end)-x_true(end-nbeta+1:end))/nrmtrue_b;
            % end

            %s_i_reshape = x(1:end-nbeta);%reshape(x(1:end-nbeta), [nlocation, ntimes]);
            %s_i_ave = sum(s_i_reshape,2);
            %output.Enrm_ave(i,1) = norm(s_i_ave - true_s_ave)/nrmtrue_ave;
        end
        output.Rnrm(i,1) = normr;
      output.Xnrm(i,1) = norm(x(:));
    end
    
    norma = norm([norma B(i,i) B(i+1,i)]);
    if isa(A,'function_handle')
      normar = norm(A(r,'transp'));
    else
      normar = norm(A'*r);
    end
    normx = norm(x(:));
    
    if normr <= restol(1)*beta+restol(2)*norma*normx || normar/(norma*normr) <= restol(2) && terminate
      if notrue % Set all the output parameters and return
        if outputparams % Large-scale problem do not store matrices
          output.U = []; %U;
          output.V = []; %V;
          output.QV = []; %QV;
          output.B = []; %B;
          output.GCVstop = GCV(:);
          output.iterations = i-1;
          output.flag = 4;
          output.alpha = alpha; % Reg Parameter at the (i-1)st iteration
          output.Alpha = Alpha(1:i-1); % Reg Parameters
        end
        close(h)
        %--------------------------------------------
        %  The following is needed for RestoreTools:
        if isa(A, 'psfMatrix')
          x_out = reshape(x, bSize);
        else
          x_out = x;
        end
        %  End of new stuff needed for RestoreTools
        %--------------------------------------------
        return
      else % Residual says stop, but continue since have x_true
        if outputparams
          output.iterations = i-1;
          output.flag = 4;
          output.alpha = alpha;
        end
      end
      terminate = 0; % Solution is already found!
    end
  else
    f = B \ vector;
%     x = Q*(V*f);
    x = QV*f;
    if outputparams
      if ~notrue
          if nomask
              xmask = x(1:end-nbeta);
          else
              xmask = x(1:end-nbeta);
              xmask = xmask(mask);
          end
          output.Enrm(i,1) = norm(xmask(:)-x_truemask(:))/nrmtruemask;
          %output.Enrm(i,1) = norm(x(1:end-nbeta)-x_true(:))/nrmtrue;
          %output.Enrm(i,1) = norm(x(:)-x_true(:))/nrmtrue;
        %output.Enrm_s(i,1) = norm(x(1:end-nbeta)-x_true(1:end-nbeta))/nrmtrue_s;
        % if nbeta ~= 0
        %     output.Enrm_b(i,1) = norm(x(end-nbeta+1:end)-x_true(end-nbeta+1:end))/nrmtrue_b;
        % end
        
        s_i_reshape = x(1:end-nbeta); 
        %reshape(x(1:end-nbeta), [nlocation, ntimes]);
        %s_i_ave = sum(s_i_reshape,2);
        %output.Enrm_ave(i,1) = norm(s_i_ave - true_s_ave)/nrmtrue_ave;
      end
      output.Rnrm(i,1) = normr;
      output.Xnrm(i,1) = norm(x(:));
    end
  end
  waitbar(i/(maxiter+1), h)
end
close(h)

if isempty(x_out) % GCV did not stop the process, so we reached max. iterations
  x_out = x;
end

%--------------------------------------------
%  The following is needed for RestoreTools:
%
if isa(A, 'psfMatrix')
  x_out = reshape(x, bSize);
end
%
%  End of new stuff needed for RestoreTools
%--------------------------------------------

if outputparams
  output.U = []; % U;
  output.V = []; %V;
  output.QV = []; %QV;
  output.B = []; %B;
  output.GCVstop = GCV(:);
  if output.alpha == 0
    output.alpha = alpha;
  end
  output.Alpha = Alpha;
end
end

%% -----------------------SUBFUNCTION---------------------------------------
function omega = findomega(bhat, s, insolv)
%
%   omega = findomega(bhat, s, insolv)
%
%  This function computes a value for the omega parameter.
%
%  The method: Assume the 'optimal' regularization parameter to be the
%  smallest singular value.  Then we take the derivative of the GCV
%  function with respect to alpha, evaluate it at alpha_opt, set the
%  derivative equal to zero and then solve for omega.
%
%  Input:   bhat -  vector U'*b, where U = left singular vectors
%              s -  vector containing the singular values
%         insolv -  inner solver method for HyBR
%
%  Output:     omega - computed value for the omega parameter.

%
%   First assume the 'optimal' regularization parameter to be the smallest
%   singular value.
%

%
% Compute the needed elements for the function.
%
m = length(bhat);
n = length(s);
switch insolv
  case 'tsvd'
    k_opt = n;
    omega = (m*bhat(k_opt)^2) / (k_opt*bhat(k_opt)^2 + 2*bhat(k_opt+1)^2);
    %  omega = ((m/2)*(bhat(k_opt)^2 + bhat(k_opt+1)^2)) / ((k_opt/2)*(bhat(k_opt)^2 +bhat(k_opt+1)^2) + 2*bhat(k_opt+1)^2)
  case 'tikhonov'
    t0 = sum(abs(bhat(n+1:m)).^2);
    alpha = s(end);
    s2 = abs(s) .^ 2;
    alpha2 = alpha^2;
    
    tt = 1 ./ (s2 + alpha2);
    
    t1 = sum(s2 .* tt);
    t2 = abs(bhat(1:n).*alpha.*s) .^2;
    t3 = sum(t2 .* abs((tt.^3)));
    
    t4 = sum((s.*tt) .^2);
    t5 = sum((abs(alpha2*bhat(1:n).*tt)).^2);
    
    v1 = abs(bhat(1:n).*s).^2;
    v2 = sum(v1.* abs((tt.^3)));
    
    %
    % Now compute omega.
    %
    omega = (m*alpha2*v2)/(t1*t3 + t4*(t5 + t0));
    
  otherwise
    error('Unknown solver');
end
end

%% ---------------SUBFUNCTION ---------------------------------------
function G = GCVstopfun(alpha, u, s, beta, m, n, insolv)
%
%  G = GCVstopfun(alpha, u, s, beta, n, insolv)
%  This function evaluates the GCV function G(i, alpha), that will be used
%     to determine a stopping iteration.
%
% Input:
%   alpha - regularization parameter at the kth iteration of HyBR
%       u - P_k^T e_1 where P_k contains the left singular vectors of B_k
%       s - singular values of bidiagonal matrix B_k
%    beta - norm of rhs b
%     m,n - size of the ORIGINAL problem (matrix A)
%  insolv - solver for the projected problem
%

k = length(s);
beta2 = beta^2;

switch insolv
  case 'tsvd'
    t2 = (abs(u(alpha+1:k+1))).^2;
    G = n*beta2*(sum(t2))/((m - alpha)^2);
  case 'tikhonov'
    s2 = abs(s) .^ 2;
    alpha2 = alpha^2;
    
    t1 = 1 ./ (s2 + alpha2);
    t2 = abs(alpha2*u(1:k) .* t1) .^2;
    t3 = s2 .* t1;
    
    num = beta2*(sum(t2) + abs(u(k+1))^2)/n;
    den = ( (m - sum(t3))/n )^2;
    G = num / den;
    
  otherwise
    error('Unknown solver');
end
end

function nrm = normM(v, M)
if isa(M, 'function_handle')
  Mv = M(v);
else
  Mv = M*v;
end
nrm = sqrt(v'*Mv);
end