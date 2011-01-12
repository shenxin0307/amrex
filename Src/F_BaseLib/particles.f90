module particle_module

  use bl_space
  use ml_layout_module

  implicit none

  type particle

     integer :: id   = -1
     integer :: cpu  = -1
     integer :: lev  = -1
     integer :: grd  = -1

     integer :: cell(MAX_SPACEDIM)

     double precision :: pos(MAX_SPACEDIM)

  end type particle

  interface index
     module procedure particle_index
  end interface index

  interface where
     module procedure particle_where
  end interface where

  interface periodic_shift
     module procedure particle_periodic_shift
  end interface periodic_shift

  interface print
     module procedure particle_print
  end interface print

  type particle_vector
     private
     integer :: size = 0
     type(particle), pointer :: d(:) => NULL()
  end type particle_vector

  interface build
     module procedure particle_vector_build
  end interface build

  interface destroy
     module procedure particle_vector_destroy
  end interface destroy
  !
  ! This includes both valid and invalid particles.
  !
  ! Valid particles are those for which "id" > 0.
  !
  ! Invalid are those for which "id" < 0.
  !
  ! We do not use the value zero for particle ids.
  !
  interface size
     module procedure particle_vector_size
  end interface size

  interface empty
     module procedure particle_vector_empty
  end interface empty
  !
  ! Returns copy of the i'th particle.  It may or may not be valid.
  !
  interface at
     module procedure particle_vector_at
  end interface at
  !
  ! This symbolically removes particles from the vector
  ! by negating the "id" of the particle.  This will be
  ! used by add() to cut down on memory allocation and copying.
  !
  interface remove
     module procedure particle_vector_remove
  end interface remove
  !
  ! This "usually" does a push_back on the space holding
  ! the particles.  If however that space is at capacity,
  ! it will try to add the particle by overwriting one that was
  ! previously removed, if possible, before allocating more space.
  ! 
  interface add
     module procedure particle_vector_add
  end interface add

  interface capacity
     module procedure particle_vector_capacity
  end interface capacity

  interface clear
     module procedure particle_vector_clear
  end interface clear

  interface print
     module procedure particle_vector_print
  end interface print
  !
  ! These are useful for testing purposes.
  !
  interface init_random
     module procedure particle_vector_init_random
  end interface init_random

  interface move_random
     module procedure particle_vector_move_random
  end interface move_random

  private :: particle_vector_reserve

contains

  subroutine particle_index(p,lev,mla,dx,problo,iv)

    type(particle),   intent(in)    :: p
    integer,          intent(in)    :: lev
    type(ml_layout),  intent(in)    :: mla
    double precision, intent(in)    :: dx(:,:)
    double precision, intent(in)    :: problo(:)
    integer,          intent(inout) :: iv(:)

    integer i

    do i = 1, mla%dim
       iv(i) = floor((p%pos(i)-problo(i))/dx(lev,i)) + lwb(mla%la(lev)%lap%pd,i)
    end do

  end subroutine particle_index
  !
  ! A return value of true means we found the particle in our grid hierarchy.
  !
  ! A value of false means it's outside our domain.
  !
  function particle_where(p,mla,dx,problo,update) result(r)

    use bl_error_module

    type(particle),   intent(inout) :: p
    type(ml_layout),  intent(inout) :: mla
    double precision, intent(in   ) :: dx(:,:)
    double precision, intent(in   ) :: problo(:)

    logical, intent(in), optional :: update

    logical                         :: r, lupdate
    integer                         :: lev, iv(MAX_SPACEDIM), dm
    type(box_intersector), pointer  :: bi(:)
    type(box)                       :: bx

    lupdate = .false. ; if ( present(update) ) lupdate = update

    dm = mla%dim

    if ( lupdate ) then
       !
       ! We have a valid particle whose position has changed slightly.
       !
       ! Try to update it smartly; i.e. less costly than the whole enchilada.
       !
       call bl_assert(p%id  > 0, 'particle_where: p%id must be  > 0')
       call bl_assert(p%grd > 0, 'particle_where: p%grd must be > 0')
       call bl_assert(p%lev > 0, 'particle_where: p%lev must be > 0')

       call bl_assert(p%lev <= size(mla%la), 'particle_where: lev out of bounds')

       call bl_assert(p%grd <= nboxes(mla%la(p%lev)%lap%bxa), 'particle_where: p%grd out of bounds')

       call particle_index(p,p%lev,mla,dx,problo,iv)

       if ( all(p%cell(1:dm) == iv(1:dm)) ) then
          !
          ! The particle hasn't left its cell.
          !
          r = .true.

          return
       end if

       if ( p%lev == size(mla%la) ) then

          p%cell(1:dm) = iv(1:dm)
          
          if ( contains(get_box(mla%la(p%lev)%lap%bxa,p%grd),iv) ) then
             !
             ! It's left its cell but's still in the same grid.
             !
             r = .true.

             return
          end if
       end if
    end if

    do lev = size(mla%la), 1, -1

       call particle_index(p,lev,mla,dx,problo,iv)

       call build(bx,iv(1:dm))

       bi => layout_get_box_intersector(mla%la(lev),bx)

       if ( size(bi) > 0 ) then

          call bl_assert(size(bi) == 1, 'particle_where: should only be one box intersector')

          p%lev        = lev
          p%grd        = bi(1)%i
          p%cell(1:dm) = iv(1:dm)

          deallocate(bi)
          !
          ! Found where the particle belongs !!!
          !
          r = .true.

          return
       end if

       deallocate(bi)

    end do

    r = .false.

  end function particle_where

  subroutine particle_periodic_shift(p,mla,dx,problo,probhi)

    use bl_error_module

    type(particle),   intent(inout) :: p
    type(ml_layout),  intent(in   ) :: mla
    double precision, intent(in)    :: dx(:,:)
    double precision, intent(in   ) :: problo(:)
    double precision, intent(in   ) :: probhi(:)

    integer                     :: i, dm, iv(MAX_SPACEDIM)
    type(box)                   :: pd
    double precision            :: plen
    double precision, parameter :: eps = 1.0d-13

    call bl_assert(p%id > 0, 'periodic_shift: not a valid particle')

    dm = mla%dim

    pd = mla%la(p%lev)%lap%pd
    
    call particle_index(p,p%lev,mla,dx,problo,iv)

    do i = 1,dm
       if ( .not. mla%pmask(i) ) cycle

       plen = (probhi(i) - problo(i))

       if ( iv(i) > upb(pd,i) ) then

          if ( p%pos(i) == probhi(i) ) then
             !
             ! Don't let particles lie exactly on the domain face.
             ! Force the particle to be outside the domain so the
             ! periodic shift will bring it back inside.
             !
             p%pos(i) = p%pos(i) + eps;
          end if

          p%pos(i) = p%pos(i) - plen

       else if ( iv(i) < lwb(pd,i) ) then

          if ( p%pos(i) == problo(i) ) then
             !
             ! Don't let particles lie exactly on the domain face.
             ! Force the particle to be outside the domain so the
             ! periodic shift will bring it back inside.
             !
             p%pos(i) = p%pos(i) - eps;
          end if

          p%pos(i) = p%pos(i) + plen

       end if
    end do

  end subroutine particle_periodic_shift

  subroutine particle_print(p)

    type(particle), intent(in) :: p

    print*, 'id   = ', p%id
    print*, 'cpu  = ', p%cpu
    print*, 'lev  = ', p%lev
    print*, 'grd  = ', p%grd
    print*, 'cell = ', p%cell
    print*, 'pos  = ', p%pos

  end subroutine particle_print

  subroutine particle_vector_build(d)
    type(particle_vector), intent(out) :: d
    allocate(d%d(d%size))
  end subroutine particle_vector_build

  subroutine particle_vector_destroy(d)
    type(particle_vector), intent(inout) :: d
    call particle_vector_clear(d)
  end subroutine particle_vector_destroy

  pure function particle_vector_empty(d) result(r)
    logical :: r
    type(particle_vector), intent(in) :: d
    r = (d%size == 0)
  end function particle_vector_empty

  pure function particle_vector_size(d) result(r)
    integer :: r
    type(particle_vector), intent(in) :: d
    r = d%size
  end function particle_vector_size

  pure function particle_vector_capacity(d) result(r)
    integer :: r
    type(particle_vector), intent(in) :: d
    r = size(d%d)
  end function particle_vector_capacity

  pure function particle_vector_at(d, i) result(r)
    type(particle) :: r
    integer, intent(in) :: i
    type(particle_vector), intent(in) :: d
    r = d%d(i)
  end function particle_vector_at

  subroutine particle_vector_reserve(d, size)
    type(particle_vector), intent(inout) :: d
    integer,               intent(in   ) :: size
    type(particle), pointer :: np(:)
    if ( size <= particle_vector_capacity(d) ) return
    allocate(np(size))
    np(1:d%size) = d%d(1:d%size)
    if ( associated(d%d) ) then
       deallocate(d%d)
    end if
    d%d => np
  end subroutine particle_vector_reserve

  subroutine particle_vector_add(d,v)
    type(particle_vector), intent(inout) :: d
    type(particle),        intent(in   ) :: v
    integer i
    if ( d%size >= particle_vector_capacity(d) ) then
       !
       ! Before reserving more space try to overwrite an invalid particle.
       ! Note that an overwrite does not change the size of the vector.
       !
       do i = 1, d%size
          if ( d%d(i)%id < 0 ) then
             d%d(i) = v
             return
          end if
       end do
       call particle_vector_reserve(d,max(d%size+1,2*d%size))
       d%size      = d%size + 1
       d%d(d%size) = v
    else
       d%size      = d%size + 1
       d%d(d%size) = v
    end if
  end subroutine particle_vector_add

  subroutine particle_vector_remove(d,i)
    type(particle_vector), intent(inout) :: d
    integer,               intent(in   ) :: i
    d%d(i)%id = -d%d(i)%id
  end subroutine particle_vector_remove

  subroutine particle_vector_clear(d)
    type(particle_vector), intent(inout) :: d
    d%size = 0
    if ( associated(d%d) ) then
       deallocate(d%d)
    end if
  end subroutine particle_vector_clear

  subroutine particle_vector_print(d, str, valid)
    type(particle_vector), intent(in)           :: d
    character (len=*),     intent(in), optional :: str
    logical,               intent(in), optional :: valid

    logical :: lvalid
    integer :: i
    !
    ! If "valid" .eq. .true. only print valid particles.
    !
    lvalid = .false. ; if ( present(valid) ) lvalid = valid

    if ( present(str) ) print*, str
    if ( empty(d) ) then
       print*, '"Empty"'
    else
       do i = 1, d%size
          if ( lvalid ) then
             if ( d%d(i)%id > 0 ) then
                call print(d%d(i))
             end if
          else
             call print(d%d(i))
          end if
       end do
    end if
  end subroutine particle_vector_print

  subroutine particle_vector_init_random(particles,icnt,iseed,mla,dx,problo,probhi)

    use mt19937_module
    use bl_error_module

    type(particle_vector), intent(inout) :: particles
    integer,               intent(in   ) :: icnt
    integer,               intent(in   ) :: iseed
    type(ml_layout),       intent(inout) :: mla
    double precision,      intent(in   ) :: dx(:,:)
    double precision,      intent(in   ) :: problo(:)
    double precision,      intent(in   ) :: probhi(:)

    integer          :: i, j, id, dm
    double precision :: rnd, len(MAX_SPACEDIM)
    type(particle)   :: p
    !
    ! Start particle IDs from 1 ...
    !
    id = 1

    dm = mla%dim

    call bl_assert(icnt  > 0, 'init_random: icnt must be > 0')
    call bl_assert(iseed > 0, 'init_random: iseed must be > 0')

    call bl_assert(empty(particles), 'init_random: particle vector should be empty')

    do i = 1,dm
       len(i) = probhi(i) - problo(i)
    end do
    !
    ! All CPUs get the same random numbers.
    !
    ! Hence they all generate the same particles.
    !
    ! But only the CPU that "owns" the particle keeps it.
    !
    call init_genrand(iseed)

    do i = 1,icnt

       do j = 1,dm
          !
          ! A random number in (0,1).
          !
          rnd = genrand_real3()

          p%pos(j) = problo(j) + (rnd * len(j))

          call bl_assert(p%pos(j) < probhi(j), 'init_random: particle out of bounds')
       end do

       if ( .not. particle_where(p,mla,dx,problo) ) then
          call bl_error('init_random: invalid particle')
       end if

       if ( local(mla%la(p%lev),p%grd) ) then
          !
          ! We own it.
          !
          p%id  = id
          p%cpu = parallel_myproc()
          id    = id + 1

          call add(particles,p)
       end if

    end do

  end subroutine particle_vector_init_random

  subroutine particle_vector_move_random(particles,mla,dx,problo,probhi)

    use mt19937_module
    use bl_error_module

    type(particle_vector), intent(inout) :: particles
    type(ml_layout),       intent(inout) :: mla
    double precision,      intent(in   ) :: dx(:,:)
    double precision,      intent(in   ) :: problo(:)
    double precision,      intent(in   ) :: probhi(:)

    integer          :: i, j, dm, sgn, lev
    double precision :: pos

    dm = mla%dim

    do i = 1, size(particles)
       !
       ! Make sure to ignore invalid particles.
       !
       if ( particles%d(i)%id <= 0 ) cycle

       lev = particles%d(i)%lev

       do j = 1, dm
          sgn = 1

          if ( genrand_real3() >= 0.5d0 ) sgn = -1

          pos = sgn * 0.25d0 * dx(lev,j) * genrand_real3()

          particles%d(i)%pos(j) = particles%d(i)%pos(j) + pos
       end do
       !
       ! The particle has moved.
       !
       ! Try to put it in the right place in the hierarchy.
       !
       if ( .not. particle_where(particles%d(i),mla,dx,problo,update=.true.) ) then
          !
          ! Try to shift particle back across any periodic boundary.
          !
          call particle_periodic_shift(particles%d(i),mla,dx,problo,probhi)

          if ( .not. particle_where(particles%d(i),mla,dx,problo) ) then
             !
             ! TODO - deal with non-periodic boundary conditions !!!
             !
             print*, 'particle leaving the domain:'

             call print(particles%d(i))

             call particle_vector_remove(particles,i)
          end if
       end if
    end do
    !
    ! TODO -- call redistribute() to give particles to the CPU that owns'm.
    !

  end subroutine particle_vector_move_random

end module particle_module
